#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
umask 077
[[ ! -e .env ]] || { echo '.env already exists; preserved.' >&2; exit 1; }

# Reuse the exact infrastructure binaries already installed, never their data.
postgres_image=$(docker inspect taiga-docker-taiga-db-1 --format '{{.Image}}')
rabbit_image=$(docker inspect taiga-docker-taiga-async-rabbitmq-1 --format '{{.Image}}')
events_image=$(docker inspect taiga-docker-taiga-events-1 --format '{{.Image}}')
protected_image=$(docker inspect taiga-docker-taiga-protected-1 --format '{{.Image}}')
gateway_image=$(docker inspect taiga-docker-taiga-gateway-1 --format '{{.Image}}')
for image in "$postgres_image" "$rabbit_image" "$events_image" "$protected_image" "$gateway_image"; do
    [[ "$image" =~ ^sha256:[a-f0-9]{64}$ ]] || { echo 'Invalid infrastructure image ID' >&2; exit 1; }
done
{
    echo 'TAIGA_DOMAIN=taiga-homolog.hakoongames.com'
    echo 'HOMOLOG_PORT=9002'
    printf 'POSTGRES_PASSWORD=%s\n' "$(openssl rand -hex 32)"
    printf 'SECRET_KEY=%s\n' "$(openssl rand -hex 48)"
    printf 'RABBITMQ_PASS=%s\n' "$(openssl rand -hex 32)"
    printf 'RABBITMQ_ERLANG_COOKIE=%s\n' "$(openssl rand -hex 32)"
    echo 'UNSPLASH_ACCESS_KEY='
    echo 'SEED_TEST_USERS_ENABLED=True'
    printf 'TEST_USERS_PASSWORD=%s\n' "$(openssl rand -hex 24)"
    printf 'POSTGRES_IMAGE=%s\n' "$postgres_image"
    printf 'RABBITMQ_IMAGE=%s\n' "$rabbit_image"
    printf 'EVENTS_IMAGE=%s\n' "$events_image"
    printf 'PROTECTED_IMAGE=%s\n' "$protected_image"
    printf 'GATEWAY_IMAGE=%s\n' "$gateway_image"
} > .env
echo 'Created homolog-only .env (mode 600). No production data or credentials copied.'
