# goChatHub Installer — Requirements Specification

Installer for private self-hosted deployments of [gochathub-server](https://github.com/gochathub/gochathub-server) and [gochathub-webui](https://github.com/gochathub/gochathub-webui) as a single Docker Compose stack.

**Status:** requirements discovery complete. Next step: `/sc:design` (architecture) then `/sc:workflow` (implementation plan).

## Decisions made (with the user)

1. **Caddy serves webui and forwards the API** — `file_server` for the static webui build plus `reverse_proxy` for `/api/*` and `/ws` to the server container. Plain HTTP inside the stack: **TLS is terminated by an upstream proxy the operator runs** (not part of this stack); a real public host is treated as https, `--http` opts out. One port exposed for the whole stack. Matches ADR-016 (cookie sessions, single origin).
2. **Installer = bash script + Makefile.** Script does the full first install interactively; Makefile provides repeat operations (`update`, `logs`, `backup`, `status`, `down`, `restart`).
3. **Installer builds images from source.** The installer repo carries both Dockerfiles; it clones both upstream repos and runs `docker build`. No changes required to the upstream repos, no external registry dependency.
4. **MinIO included in the stack.** Attachments and avatar upload work out of the box; S3 env vars wired to the server.

## Goal

One command on a fresh machine (with `git`, `docker`, `docker compose`, `make`) produces a working goChatHub deployment: web UI reachable (https behind the operator's TLS proxy, or plain HTTP on localhost / with `--http`), live messaging working, admin account created, attachments uploadable.

## Stack shape (what the installer must produce)

| Container | Image source | Role |
|---|---|---|
| `webui` | built by installer (bun `install` + `build` → static assets) | served by Caddy as static files |
| `server` | built by installer (Go multi-stage build from `cmd/chatserver`) | REST + WebSocket API |
| `postgres` | `postgres:16-alpine` (matches dev usage) | only durable state |
| `minio` | official MinIO image + bucket bootstrap | object storage for attachments/avatars |
| `caddy` | `caddy:*` image | serves webui statically, forwards `/api` and WebSocket to server |

Volumes: postgres data, minio data, caddy config (persist across restarts). Internal network only; exactly one published port (Caddy HTTP), configurable.

## Functional requirements

**FR-6 CLI availability**: the server admin CLI must be trivially runnable in a containerized deployment — a `ghc` wrapper in the deploy dir (`docker compose run --rm server gochathub-server "$@"`), working with the server container stopped for emergency admin tasks, plus a `make cli ARGS=…` alias. No PATH installation required.

**FR-1 Install script** (`install.sh`):
- Verify prerequisites (`git`, `docker`, `docker compose`) and fail with a clear message if missing.
- Clone `gochathub-server` and `gochathub-webui` at a **pinned commit SHA** (SHAs recorded in the installer repo, overridable by flag/env). **Both repos are public open source** — plain `git clone` over https, no auth assumed.
- Build the two images.
- Generate `docker-compose.yml`, `Caddyfile`, `.env` (DB user/password auto-generated random; MinIO root password auto-generated; port prompted, sensible default).
- Create the database, run `gochathub-server migrate` (explicit step or `MIGRATIONS_ON_SERVE=1` — design decision, both are documented options).
- Create the MinIO bucket and wire `S3_ENDPOINT/S3_BUCKET/S3_ACCESS_KEY/S3_SECRET_KEY/S3_REGION/S3_USE_TLS` to the server.
- Prompt for the **first admin account** (name + password) and create it via the admin CLI (`gochathub-server user create ... --role admin`).
- Set server env: `DATABASE_URL`, `LISTEN_ADDR`, `COOKIE_SECURE=true` and `ORIGIN=https://<host>` (false / `http://<host>:<port>` with `--http` or on localhost), `S3_ENDPOINT=http://minio:9000` + `S3_PUBLIC_ENDPOINT=https://<host>` behind the proxy, `TRUST_PROXY=true` (Caddy passes the upstream's `X-Forwarded-*`), `MAX_UPLOAD_BYTES` default.
- Idempotent re-run: skips completed steps, never destroys data.

**FR-2 Makefile targets** (operate on the generated deployment):
- `install` — full first install (wraps the script's non-destructive flow).
- `update` — re-clone/pull to the pinned SHAs, rebuild images, restart changed containers. Database migrations handled (re-run migrate before start).
- `logs` — compose logs (all services or by name).
- `status` / `ps` — container health.
- `backup` — `pg_dump` to a timestamped file.
- `restart` / `down` / `up` — lifecycle.
- `uninstall` — stop and remove containers; **data volumes require explicit confirmation** (never silently dropped).

**FR-3 Dockerfiles (in installer repo):**
- Server: multi-stage Go build, final image runs the single binary with subcommands.
- Webui: bun-based build (`bun install`, `bun run build`), final stage copies the static `dist/` output (no Node runtime needed at serving time — Caddy serves it).

**FR-4 Caddy configuration:** plain HTTP listener, `file_server` for the webui build, `reverse_proxy` for the API and WebSocket upgrade to the server container, plus `/<bucket>/*` to MinIO for presigned attachment URLs. No TLS and no automatic certificates in this stack; trusts `X-Forwarded-*` from private upstream proxies.

- **FR-5 Port collision handling**: at install time, check both published ports (edge, MinIO) against everything listening on the host — Docker-published or not — and auto-shift to the next open port (`preferred +1` up to +20 before failing with flag guidance). Explicitly requested ports (`--port` / `--minio-port`, or existing `.env` values) are strict: taken → fail fast naming the conflict. Re-runs must exclude this deployment's own already-published ports from the check (else the script would flag its own containers as collisions).

## Non-functional requirements

- **NFR-1 Zero upstream changes**: neither gochathub repo needs modification for installation to work.
- **NFR-2 Deterministic builds**: pinned commit SHAs; repeat installs of the same version produce equivalent results.
- **NFR-3 Secrets hygiene**: generated passwords live only in generated `.env` (gitignored); never echoed to logs; never committed.
- **NFR-4 Data safety**: `update` must not require wiping volumes; explicit destructive operations only.
- **NFR-5 Linux/amd64 first** (matches server repo target). ARM noted as out of scope unless requested.
- **NFR-6 Minimal surface**: one published port; postgres, minio and server reachable only on the compose network.

## User stories / acceptance criteria

- **AC-1** On a fresh Linux machine with git/docker/make, running `./install.sh` ends with the URL to log in, having created one working admin account.
- **AC-2** Two logged-in users exchange a message; it appears live via WebSocket without a refresh.
- **AC-3** A user uploads an attachment (file ≤ `MAX_UPLOAD_BYTES`); recipient can download it. Avatar upload also works.
- **AC-4** Re-running `./install.sh` after a completed install does not lose data or credentials.
- **AC-5** `make update` pulls the pinned SHAs, rebuilds, brings the stack back up with existing data intact, and applies pending migrations.
- **AC-6** `make backup` produces a restorable Postgres dump; `make down` stops everything; restarting the stack restores state.
- **AC-7** If any prerequisite is missing, the script fails fast with a message naming the missing tool.
- **AC-8** With defaults taken (e.g. 8080 busy), fresh install still completes: shifted ports land in `.env`, summary reports the change, stack reachable at the new port. With `--port <taken>`, install exits naming the conflict.

## Out of scope (per current decisions)

- TLS/HTTPS termination and certificate management (Let's Encrypt, internal CA): the operator's upstream proxy owns these.
- ntfy/UnifiedPush push configuration (server supports it, but installer leaves `PUSH_*` unset; browser Web Push still works — VAPID keys auto-generate on first boot).
- Android client installation.
- Publishing images to a registry (revisit if installer is shared publicly). If repos become public and GHCR images appear, installer can switch sources — not now.

## Resolved since discovery

- **Q1 Audience** → **Public open source installer** (repos and installer itself go public). Implied requirements: no auth assumptions, plain public clone, friendly fail-fast errors, non-interactive mode (`--port`, `--admin`, env vars / flags for scripted deployments) alongside interactive defaults, and an install README for the installer repo.
- **Q3 Pinning** → **Frozen SHA default**. Installer pins both repos to recorded SHAs (reproducible installs); `make update` bumps the pin explicitly and reruns rebuild + migrate.
- **Q2 Port** → conventional default; script prompts with 8080 default, `--port` flag override, publish on `0.0.0.0` (deployment host decides exposure; localhost-only setups can map it off).