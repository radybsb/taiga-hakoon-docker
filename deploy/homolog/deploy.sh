#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
umask 077
exec 9>.deploy.lock
flock -n 9 || { echo 'Another homolog deployment is active' >&2; exit 1; }

front=${1:?Provide the frontend image}
back=${2:?Provide the backend image}
for component in front back; do
    if [[ "$component" == front ]]; then image=$front; else image=$back; fi
    [[ "$image" =~ ^ghcr\.io/radybsb/taiga-hakoon-${component}:(sha-[a-f0-9]{40}-[0-9]+-[0-9]+)$ || "$image" =~ ^ghcr\.io/radybsb/taiga-hakoon-${component}@sha256:[a-f0-9]{64}$ ]] || {
        echo "Use an immutable GHCR image for $component" >&2; exit 1;
    }
done
[[ -s .env ]] || { echo 'Run bootstrap.sh first' >&2; exit 1; }
candidate=$(mktemp .candidate.XXXXXX)
trap 'rm -f "$candidate"' EXIT
printf 'FRONTEND_IMAGE=%s\nBACKEND_IMAGE=%s\n' "$front" "$back" > "$candidate"
compose=(docker compose -p taiga-homolog --env-file .env --env-file "$candidate" -f compose.yml)
"${compose[@]}" config --quiet
# Fail before touching anything if the old shared-backend preview still owns the port.
port=$(sed -n 's/^HOMOLOG_PORT=//p' .env)
port=${port:-9002}
if [[ -z "$("${compose[@]}" ps -q --status running taiga-gateway)" ]] && ss -ltnH "sport = :$port" | grep -q .; then
    echo "Port $port is occupied. Stop only the old preview frontend before the first deploy." >&2
    exit 1
fi
"${compose[@]}" pull taiga-front taiga-back taiga-async
mkdir -p backups
stamp=$(date -u +%Y%m%dT%H%M%SZ)
if [[ -s .release.env ]]; then cp .release.env "backups/$stamp.release.env"; fi
"${compose[@]}" up -d --wait --wait-timeout 300 taiga-db taiga-async-rabbitmq taiga-events-rabbitmq
"${compose[@]}" exec -T taiga-db pg_dump -U taiga_homolog -d taiga_homolog -Fc > "backups/$stamp.dump"
# Preserve the data volume, and stop old workers before applying migrations.
"${compose[@]}" stop taiga-async
"${compose[@]}" up -d --no-deps --wait --wait-timeout 600 taiga-back
"${compose[@]}" exec -T taiga-back python manage.py check
seed_enabled=$("${compose[@]}" exec -T taiga-back python -c 'import os; print(os.getenv("SEED_TEST_USERS_ENABLED", "False").lower())')
if [[ "$seed_enabled" == true ]]; then
    "${compose[@]}" exec -T taiga-back python manage.py seed_test_users
fi
"${compose[@]}" up -d --no-deps --wait --wait-timeout 180 taiga-front taiga-async taiga-events taiga-protected
"${compose[@]}" up -d --no-deps --force-recreate taiga-gateway
"${compose[@]}" exec -T taiga-gateway nginx -t
curl --fail --silent --show-error --retry 10 --retry-connrefused --retry-delay 2 "http://127.0.0.1:$port/healthz" > /dev/null
curl --fail --silent --show-error --retry 10 --retry-delay 2 "http://127.0.0.1:$port/api/v1/projects" > /dev/null
cp "$candidate" .release.env
printf '%s frontend=%s backend=%s\n' "$stamp" "$front" "$back" >> backups/deployments.log
"${compose[@]}" ps
echo 'Homolog deployment passed. Production was not modified.'
