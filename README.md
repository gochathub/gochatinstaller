# gochatinstaller

Self-hosted goChatHub installer: one command boots [gochathub-server](https://github.com/gochathub/gochathub-server) + [gochathub-webui](https://github.com/gochathub/gochathub-webui) as a Docker Compose stack (Caddy edge serving the web UI, API/WebSocket forwarding, Postgres, MinIO object storage). Plain HTTP, no TLS — run it on a trusted network.

## Install

Requires: `git`, `docker` (+ compose plugin), `make` ops optional; `ss` (ships with iproute2).

```sh
git clone https://github.com/gochathub/gochatinstaller
cd gochatinstaller
./install.sh                      # deploys ./gochathub-deploy, prompts for ports + admin
```

Common flags (all also work with `--non-interactive` for scripted deploys):

```sh
./install.sh ~/gochathub \
  --port 8080 --minio-port 9000 \
  --public-host chat.example.lan:8080 \
  --admin root
# scripted:
ADMIN_PASSWORD=... ./install.sh /opt/ghc --non-interactive --admin root
```

| Flag | Meaning |
|---|---|
| `[target-dir]` | deployment directory (default `./gochathub-deploy`) |
| `--port N` | edge HTTP port; **strict** — fails if taken (unrequested default ports auto-shift +1) |
| `--minio-port N` | MinIO S3 API port, published to the host; same strict/auto rules |
| `--public-host HOST:PORT` | browser-visible origin (drives session `ORIGIN` and MinIO presigned endpoints) |
| `--admin NAME` + `ADMIN_PASSWORD` env | initial admin account (skipped if one exists) |
| `--sha server=X --sha webui=Y` | temporary checkout override (interactive use only) |
| `--bump-pins` | record both repos' current `main` SHAs in `pins.env`, then update |
| `--turnstile-site-key KEY` + `TURNSTILE_SECRET` env | enable Cloudflare Turnstile on login (both or neither; see below) |

The stack publishes **two host ports**: edge HTTP (`PUBLISHED_PORT`) and the MinIO S3 API (`MINIO_PUBLISHED_PORT`) — attachment uploads use presigned URLs that the browser fetches directly. If the machine sits behind NAT without forwarded ports, chat works but attachments don't.

## Operations (inside the deploy dir)

`install.sh` generates a Makefile and a `ghc` CLI wrapper there:

```
make update            # re-pull pinned SHAs, rebuild (layer-cached), restart — data safe
make backup            # pg_dump → backups/db-<ts>.sql.gz
make logs  / status    # compose logs -f / ps
make down  / install   # stop without removing volumes / re-run non-interactive install
make bump-pins         # advance both pinned SHAs to repo main heads
./ghc <subcommand>     # server admin CLI in the container, e.g.
./ghc user list
./ghc user create alice --display-name Alice
./ghc room list --json
./ghc token create <userId> my-app     # API token for automation
```

CLI passes through all server flags (`--json`, `--yes`, `--password-stdin`) and works while the server container is stopped.

### Backup restore

```sh
gunzip -c backups/db-<ts>.sql.gz | docker compose exec -T postgres \
  sh -c 'exec psql -U "$POSTGRES_USER" -d "$POSTGRES_DB"'
```

MinIO objects live in the `miniodata` named volume; to move them, tar the volume (`docker run --rm -v <project>_miniodata:/data -v $PWD:/out alpine tar czf /out/minio.tgz /data`) and untar into the replacement volume.

### IPv6 note

`--public-host` must be an IPv4 or DNS host. IPv6 literals break the MinIO presigned host derivation (use a DNS name or IPv4).

## Login protection

### Two-factor authentication (TOTP)

Nothing to configure — it ships with the pinned server/web pair. Each user opts
in under Settings → Account → Two-factor authentication (QR code + one-time
backup codes). If a user loses their authenticator, an admin removes the factor
and revokes their sessions:

```sh
./ghc user 2fa-reset <username>
```

### Cloudflare Turnstile (optional captcha)

Adds a Turnstile widget to the sign-in form; the server verifies each token
with Cloudflare before checking the password. Off unless you give both keys
(create a widget in the Cloudflare dashboard first):

```sh
# first install, interactive: the installer asks once (Enter skips)
# scripted / re-configure an existing install:
TURNSTILE_SECRET=... ./install.sh <target-dir> --non-interactive --turnstile-site-key <site key>
```

- The **site key** is public and is baked into the web bundle at image-build
  time, so changing it rebuilds the caddy image. The **secret** only lives in
  the deploy dir's `.env` (mode 0600) and is passed to the server container.
- Re-runs keep the stored keys; pass new values to rotate them.
- When `--public-host` is a DNS name the installer also pins tokens to that
  hostname (`TURNSTILE_HOSTNAME`). It does not pin IPs or `localhost`.
- Turnstile widgets need a DNS hostname in the Cloudflare dashboard's hostname
  list — an IP-only install (the default `localhost:PORT` or a LAN IP) can only
  use Cloudflare's [test keys](https://developers.cloudflare.com/turnstile/troubleshooting/testing/)
  (site `1x00000000000000000000AA`, secret `1x0000000000000000000000000000000AA`).

## Push notifications (ntfy)

Out of scope by design. Browser Web Push works out of the box (VAPID keys auto-generate in the database on first boot). To enable UnifiedPush for Android, edit `.env` … the compose `server.environment` with:

```
PUSH_ALLOW_HOSTS: <your-ntfy-host>
PUSH_NTFY_QUERY: up
```

and restart `docker compose up -d`.

## Files

- `REQUIREMENTS.md` — requirements
- `docs/DESIGN.md` — architecture, decisions, verification notes
- `pins.env` — pinned upstream SHAs (the webui snapshot must stay in contract-sync with the server pin; bump both together via `make bump-pins`)