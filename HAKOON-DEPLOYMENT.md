# Hakoon release procedure

## Current production

Production remains in `/opt/taiga/taiga-docker`, on loopback port 9000 and
`https://taiga.hakoongames.com`. Its frontend was promoted to
`hakoon/taiga-front:preview-20261017-02`. Keep including
`-f docker-compose.yml -f compose.frontend-production.yml` when updating that
existing stack. Do not replace its database or run the new homolog Compose there.

The old preview is `taiga-preview-frontend-1`, on port 9002. It still uses the
production API. It must be stopped before starting the isolated homolog gateway.

## Repositories and branches

The new repositories contain a clean snapshot of the customized source, retaining
upstream licenses and authorship files. They intentionally do not inherit the old
Git history, because the old Docker repository tracked a runtime `.env`.
The original local repositories and their history remain untouched.

- `main`: initial baseline / reviewed release source.
- `develop`: ongoing development and homolog candidates.
- Neither branch deploys directly to production.

Work from the new checkouts after this migration. Changes made in the original
`taiga-front`, `taiga-back` or `taiga-docker` folders are not automatically copied.

## CI and container images

Frontend and backend pushes to `develop`, manual runs, and PRs to `main`/`develop` build and test their images
on GitHub-hosted runners. PRs do not publish images. Successful pushes publish:

```
ghcr.io/radybsb/taiga-hakoon-front:sha-<frontend commit SHA>-<workflow run ID>-<attempt>
ghcr.io/radybsb/taiga-hakoon-back:sha-<backend commit SHA>-<workflow run ID>-<attempt>
```

Branch tags are convenient pointers, but deployment only accepts immutable SHA
tags or digests. Each component's workflow summary contains the exact tag.
The frontend smoke test checks runtime config, SPA routes, asset caching/404s and
same-origin proxying using disposable containers without network access.
Backend CI tests Wiki metadata/links, multiple assignees, backgrounds and
attachments against a disposable PostgreSQL/RabbitMQ environment before building.
Legacy upstream workflows are retained in `.github/legacy-workflows/` as reference.

Images are published using the repository's automatic `GITHUB_TOKEN` with
`packages: write`; no personal write token is committed. If GHCR refuses the
first publish, check repository Actions permissions and the package's repository
access settings. Package visibility is independent of repository visibility.
Private packages require a read-only registry credential on the VPS.

## Isolated homolog architecture

`deploy/homolog/compose.yml` is a standalone Compose project named `taiga-homolog`.
It has its own PostgreSQL, two RabbitMQ services, backend, worker, frontend,
events, protected media service, gateway, network and named volumes.
No network, volume, database, media or secrets are shared with production.
Only `127.0.0.1:9002` is published; the existing host Nginx/TLS domain can remain.

Email is written to the console and webhooks are disabled. The database starts
empty; no production users or records are imported automatically. Unsplash needs
its own value in the ignored homolog `.env` if photo search is desired.

The measured VPS has 4 GB RAM, about 1.6 GB available and 30 GB free disk.
This low-traffic configuration uses one API worker and one Celery worker, log
rotation and memory limits totalling about 1.6 GB. These are limits, not measured
steady-state consumption. There is no swap. Monitor memory/OOM counters before
considering the installation validated; resource exhaustion warrants more RAM or
a separate VPS. Builds do not run on the VPS.

## First installation (operator terminal on the VPS)

Only after image CI passes and the registry credentials are configured:

```bash
cd /opt/taiga
git clone --branch develop https://github.com/radybsb/taiga-hakoon-docker.git
cd taiga-hakoon-docker/deploy/homolog
bash bootstrap.sh
```

Bootstrap generates new secrets in a mode-600 `.env` and pins the exact existing
infrastructure image IDs from the production containers. It reads only image IDs;
it never copies production volumes, secrets or database contents. Existing image
layers can be reused without sharing application state. Back up this `.env`
privately; it is required to access the new volumes on later deployments.

If packages are private, sign in interactively using a GitHub token restricted to
`read:packages` for the two images. Do not paste the token into chat or shell args:

```bash
docker login ghcr.io -u radybsb
```

Once ready to replace the old preview, stop that container only, and deploy:

```bash
docker stop taiga-preview-frontend-1
bash deploy.sh \
  ghcr.io/radybsb/taiga-hakoon-front:sha-FRONTEND_COMMIT_SHA-RUN_ID-ATTEMPT \
  ghcr.io/radybsb/taiga-hakoon-back:sha-BACKEND_COMMIT_SHA-RUN_ID-ATTEMPT
```

Copy the full image names from successful workflow summaries. Unique run/attempt
suffixes avoid overwriting a release on retries or manual rebuilds. The script
rejects `latest`, mutable branch tags, wrong repositories and invalid names.
It checks the port before modifying services, pulls only the two custom images,
backs up the homolog database before migrations, stops old workers, waits for the
API, and recreates the gateway after upstream IPs change. It never calls `down -v`
and never targets the production Compose project. Database backups may contain
private homolog data; they stay on the VPS with restrictive permissions.

After a successful first deployment:

```bash
docker compose -p taiga-homolog --env-file .env --env-file .release.env \
  -f compose.yml exec taiga-back python manage.py createsuperuser
curl -I https://taiga-homolog.hakoongames.com/
docker stats --no-stream
```

Create the initial user interactively; no default shared password is provided.
Validate login, a test project, attachments, editing, background search, events
and persistence after restart. Check that production still serves its own data.

## CD through GitHub Actions

In `taiga-hakoon-docker`, create a GitHub Environment named `homolog`, restricted
to reviewed `main`/`develop` refs and with any desired approval protection.
Configure its variables `SSH_HOST` (real hostname/IP, not the local `hakoon` alias)
and `SSH_USER`, plus `SSH_PORT` (57726 on the current VPS; defaults to 22).
Configure secrets `SSH_PRIVATE_KEY` (dedicated deployment key) and
`SSH_KNOWN_HOSTS` (host key independently verified against the VPS).
For a nonstandard port, the known-host entry must match `[hostname]:port`.
Do not disable SSH host-key checking. Provisioning a deploy identity with Docker
access is privileged and must be performed deliberately by the operator.

The remote directory `/opt/taiga/taiga-hakoon-docker` and its homolog `.env` must
already exist, and its SSH user must be able to use Docker and write there.
The registry login is stored on the VPS; SSH secrets exist only in the Docker
repository's environment, not the frontend/backend repositories.

After component CI passes, run **Deploy isolated homolog** manually in Actions,
providing both complete `sha-...` image names. Deployment is serialized; a new run
does not cancel a migration in progress. Only versioned deployment configuration
is uploaded, never local `.env` files. A successful deploy records the pair in
`.release.env` and `backups/deployments.log`.

Production deployment is intentionally not automated during this migration.
Validate this environment first, then prepare a production-specific release using
the existing production data/volumes, an explicit database/media backup and a
separate production environment approval. Do not apply homolog Compose to prod.

## Failures and recovery

Failed migrations/deployments stop the workflow. Database schemas are never
automatically rolled back. `.release.env` records only the last successful pair;
some containers may already have changed during a failed attempt. Inspect logs
before retrying, and assess migration compatibility before reverting images.
Use `backups/*.dump` only for an explicit, reviewed homolog database restore.

To temporarily restore the old shared-backend preview, stop the new homolog
gateway to free port 9002, then `docker start taiga-preview-frontend-1`.
This restores the previous preview behavior; it does not undo homolog migrations
or touch production. Never run both gateways on the same port.

## References

- https://docs.github.com/en/actions/tutorials/publish-packages/publish-docker-images
- https://docs.docker.com/compose/how-tos/project-name/
