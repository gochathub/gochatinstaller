#!/usr/bin/env bash
# goChatHub installer — see docs/DESIGN.md.
# Usage: ./install.sh [target-dir] [--port N] [--minio-port N] [--public-host HOST:PORT]
#                 [--admin NAME] [--non-interactive] [--sha server=X --sha webui=Y] [--bump-pins]
set -euo pipefail

INSTALLER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_URL="https://github.com/gochathub"

usage() { sed -n '2,4p' "$0" | sed 's/^# //'; }
die() { echo "error: $*" >&2; exit 1; }
info() { echo "==> $*" >&2; }
randhex() { head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n'; }

TARGET=""
PORT="" MINIO_PORT="" PUBLIC_HOST=""
ADMIN_NAME=""
NONINTERACTIVE=0 BUMP_PINS=0
SHA_SERVER="" SHA_WEBUI=""

while [ $# -gt 0 ]; do
	case "$1" in
		--port) PORT="${2:?}" ; shift 2 ;;
		--minio-port) MINIO_PORT="${2:?}" ; shift 2 ;;
		--public-host) PUBLIC_HOST="${2:?}" ; shift 2 ;;
		--admin) ADMIN_NAME="${2:?}" ; shift 2 ;;
		--non-interactive) NONINTERACTIVE=1 ; shift ;;
		--bump-pins) BUMP_PINS=1 ; shift ;;
		--sha) case "${2:?}" in
			server=*) SHA_SERVER="${2#server=}" ;;
			webui=*) SHA_WEBUI="${2#webui=}" ;;
			*) die "--sha takes server=<sha> or webui=<sha>" ;;
		esac ; shift 2 ;;
		-h|--help) usage ; exit 0 ;;
		-*) usage >&2 ; die "unknown flag: $1" ;;
		*) TARGET="$1" ; shift ;;
	esac
done

# ---- 1. prerequisites -------------------------------------------------------
for c in git docker ss; do
	command -v "$c" >/dev/null || die "missing prerequisite: $c"
done
docker compose version >/dev/null 2>&1 || die "missing prerequisite: docker compose plugin"
docker info >/dev/null 2>&1 || die "docker daemon not running"

# shellcheck source=pins.env
source "$INSTALLER_DIR/pins.env"
SERVER_SHA="${SHA_SERVER:-$GOCHATHUB_SERVER_SHA}"
WEBUI_SHA="${SHA_WEBUI:-$GOCHATHUB_WEBUI_SHA}"

TARGET="${TARGET:-$PWD/gochathub-deploy}"
COMPOSE_FILE="$TARGET/docker-compose.yml"
ENV_FILE="$TARGET/.env"
CLONES="$TARGET/clones"

# ---- 2. .env: reuse or generate --------------------------------------------
if [ -f "$ENV_FILE" ]; then
	# shellcheck source=/dev/null
	source "$ENV_FILE"
	for k in PUBLISHED_PORT MINIO_PUBLISHED_PORT PUBLIC_HOST POSTGRES_PASSWORD MINIO_ROOT_PASSWORD; do
		[ -n "${!k:-}" ] || die ".env missing $k — fix $ENV_FILE or remove it (fresh install only)"
	done
else
	: "${POSTGRES_USER:=chat}" ; : "${POSTGRES_DB:=chat}"
	: "${MINIO_ROOT_USER:=gochathub}" ; : "${S3_BUCKET:=gochathub}"
	POSTGRES_PASSWORD="$(randhex)"; MINIO_ROOT_PASSWORD="$(randhex)"
fi

# .env keys are the compose-facing names; map them to the port variables
[ -n "$PORT" ] || PORT="${PUBLISHED_PORT:-}"
[ -n "$MINIO_PORT" ] || MINIO_PORT="${MINIO_PUBLISHED_PORT:-}"

# ---- 3. port collision check (FR-5) ----------------------------------------
own_ports() { # published ports of THIS project only (empty before first up)
	docker compose -f "$COMPOSE_FILE" ps --format json 2>/dev/null \
		| grep -o '"PublishedPort":[0-9]*' | grep -o '[0-9]*$' || true
}

taken() {
	local listeners
	listeners="$(ss -ltnH 2>/dev/null | awk '{print $4}')" || return 1
	printf '%s\n' "$listeners" | grep -qE "[:]$1$"
}

taken_by_other() { # busy, and not by our own already-running compose project
	taken "$1" || return 1
	! own_ports | grep -qx "$1"
}

# $1 preferred port; $2 flag name, empty = value was generated (auto-shift +1..+20)
shift_port() {
	local p="$1" n=0
	if [ -n "$2" ]; then
		taken_by_other "$p" && die "requested port $p in use by another service — free it or pick another (--$2)"
		printf '%s\n' "$p"
		return 0
	fi
	while taken_by_other "$p"; do
		n=$((n + 1)); [ "$n" -le 20 ] || die "no free port near $p — pick one with the --port/--minio-port flag"
		p=$((p + 1))
	done
	[ "$p" -eq "$1" ] || info "port $1 busy (not this stack) — using $p"
	printf '%s\n' "$p"
}

PREFERRED_PORT="${PORT:-8080}"
PORT="$(shift_port "$PREFERRED_PORT" "${PORT:+port}")"
PREFERRED_MINIO="${MINIO_PORT:-9000}"
MINIO_PORT="$(shift_port "$PREFERRED_MINIO" "${MINIO_PORT:+minio-port}")"
: "${PUBLIC_HOST:=localhost:$PORT}" # derived AFTER the shift so ORIGIN/S3_ENDPOINT follow it
# host-only form for the MinIO presigned endpoint (IPv6 literals unsupported — README)
MINIO_PUBLIC_HOST="${PUBLIC_HOST%:*}"

# ---- 4. clones at pinned SHAs ----------------------------------------------
sync_clone() { # $1 key word (SERVER|WEBUI), $2 repo, $3 sha
	local dir="$CLONES/$2"
	if [ ! -d "$dir" ]; then
		info "cloning $2"
		git clone -q "$REPO_URL/$2" "$dir" \
			|| die "clone failed for $2 — repository unreachable (public? credentials configured?)"
	fi
	git -C "$dir" fetch -q origin
	git -C "$dir" checkout -qf "$3"
	[ "$BUMP_PINS" -eq 1 ] || return 0
	local head; head="$(git -C "$dir" rev-parse origin/main)"
	sed -i "s/^GOCHATHUB_${1}_SHA=.*/GOCHATHUB_${1}_SHA=$head/" "$INSTALLER_DIR/pins.env"
	info "pinned $2 at $head"
}
mkdir -p "$TARGET"
sync_clone SERVER gochathub-server "$SERVER_SHA"
sync_clone WEBUI gochathub-webui "$WEBUI_SHA"
BUMP_PINS=0 # pins rewrite is once per run; later --sha overrides are ephemeral

if [ "$NONINTERACTIVE" -eq 1 ] && { [ -n "$SHA_SERVER" ] || [ -n "$SHA_WEBUI" ]; }; then
	die "--sha with --non-interactive would write nondeterministic state; use pins.env instead"
fi

# ---- 5. derived files -------------------------------------------------------
cp "$INSTALLER_DIR/docker-compose.yml" "$COMPOSE_FILE"
cp "$INSTALLER_DIR/Caddyfile" "$TARGET/Caddyfile"

cat > "$TARGET/.dockerignore" <<'EOF'
*
!clones/
!clones/**
!Caddyfile
EOF

cat > "$ENV_FILE" <<EOF
# Generated by gochatinstaller. Passwords are random secrets; file mode 0600.
PUBLISHED_PORT=$PORT
MINIO_PUBLISHED_PORT=$MINIO_PORT
PUBLIC_HOST=$PUBLIC_HOST
MINIO_PUBLIC_HOST=$MINIO_PUBLIC_HOST
POSTGRES_USER=${POSTGRES_USER:-chat}
POSTGRES_DB=${POSTGRES_DB:-chat}
POSTGRES_PASSWORD=$POSTGRES_PASSWORD
MINIO_ROOT_USER=${MINIO_ROOT_USER:-gochathub}
MINIO_ROOT_PASSWORD=$MINIO_ROOT_PASSWORD
S3_BUCKET=${S3_BUCKET:-gochathub}
EOF
chmod 600 "$ENV_FILE"

cat > "$TARGET/ghc" <<'EOF'
#!/bin/sh
exec docker compose -f "$(dirname "$0")/docker-compose.yml" run --rm --quiet-pull server gochathub-server "$@"
EOF
chmod +x "$TARGET/ghc"

cat > "$TARGET/Makefile" <<EOF
# goChatHub deployment operations — generated by install.sh
INSTALLER_DIR := $INSTALLER_DIR
DEPLOY_DIR := $TARGET
COMPOSE := docker compose -f \$(DEPLOY_DIR)/docker-compose.yml
.PHONY: install update bump-pins logs status backup restart up down uninstall cli help
install:
	bash \$(INSTALLER_DIR)/install.sh \$(DEPLOY_DIR) --non-interactive
update: install
bump-pins:
	bash \$(INSTALLER_DIR)/install.sh \$(DEPLOY_DIR) --bump-pins --non-interactive
logs:
	\$(COMPOSE) logs -f
status:
	\$(COMPOSE) ps
backup:
	@mkdir -p backups
	\$(COMPOSE) exec -T postgres sh -c 'exec pg_dump -U "\$\$POSTGRES_USER" -d "\$\$POSTGRES_DB"' | gzip > backups/db-\$\$(date +%Y%m%d-%H%M%S).sql.gz
	@echo "backup written — see ls backups/"
restart:
	\$(COMPOSE) restart
up:
	\$(COMPOSE) up -d
down:
	\$(COMPOSE) down
uninstall:
	\$(COMPOSE) down
cli:
	\$(DEPLOY_DIR)/ghc \$(ARGS)
help:
	@echo "make install|update|bump-pins|logs|status|backup|restart|up|down|uninstall | cli ARGS='user list'"
EOF

# ---- 6. images --------------------------------------------------------------
info "building gochathub/server:local"
docker build -q -t gochathub/server:local \
	-f "$INSTALLER_DIR/docker/server.Dockerfile" "$CLONES/gochathub-server"
info "building gochathub/caddy:local (webui dist baked in)"
docker build -q -t gochathub/caddy:local \
	-f "$INSTALLER_DIR/docker/caddy.Dockerfile" "$TARGET"

# ---- 7. start + wait --------------------------------------------------------
info "starting stack"
docker compose -f "$COMPOSE_FILE" up -d

ready=0
for _ in $(seq 1 60); do
	if docker compose -f "$COMPOSE_FILE" exec -T server wget -qO- http://server:8080/healthz >/dev/null 2>&1; then
		ready=1; break
	fi
	sleep 2
done
if [ "$ready" -ne 1 ]; then
	info "server failed to become healthy in 120s — recent logs:"
	docker compose -f "$COMPOSE_FILE" logs --tail=50 server
	die "server did not come up"
fi

# ---- 8. admin bootstrap -----------------------------------------------------
admins="$(docker compose -f "$COMPOSE_FILE" exec -T server gochathub-server user list 2>/dev/null \
	| awk '$4 == "admin"' || true)"
if [ -n "$admins" ]; then
	info "admin account exists, skipping bootstrap"
else
	if [ -z "$ADMIN_NAME" ]; then
		[ "$NONINTERACTIVE" -eq 0 ] || die "non-interactive install needs --admin NAME and ADMIN_PASSWORD"
		read -rp "admin username: " ADMIN_NAME
	fi
	ADMIN_PASSWORD="${ADMIN_PASSWORD:-}"
	if [ -z "$ADMIN_PASSWORD" ]; then
		[ "$NONINTERACTIVE" -eq 0 ] || die "ADMIN_PASSWORD env not set for --non-interactive"
		read -rsp "password for $ADMIN_NAME: " ADMIN_PASSWORD; echo
		read -rsp "confirm: " ADMIN_PASSWORD2; echo
		[ "$ADMIN_PASSWORD" = "$ADMIN_PASSWORD2" ] || die "passwords do not match"
	fi
	printf '%s\n' "$ADMIN_PASSWORD" \
		| docker compose -f "$COMPOSE_FILE" exec -T server \
			gochathub-server user create "$ADMIN_NAME" --role admin --password-stdin - >/dev/null
	info "admin account '$ADMIN_NAME' created"
fi

# ---- 9. summary -------------------------------------------------------------
echo
echo "goChatHub is up."
echo "  web:      http://$PUBLIC_HOST"
echo "  api:      http://$PUBLIC_HOST/api/v1"
echo "  minio:    http://$PUBLIC_HOST:$MINIO_PORT (attachments, browser-reachable)"
echo "  cli:      cd $TARGET && ./ghc <user|room|token> ..."
echo "  ops:      cd $TARGET && make help"
echo "  data:     $TARGET (docker volumes pgdata, miniodata)"