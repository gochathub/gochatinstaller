# Build context: the deploy dir (installs writes <target>/.dockerignore).
# Stage 1 builds the webui from its clone; stage 2 bakes dist + Caddyfile into caddy.
FROM oven/bun:1 AS webui
WORKDIR /src
COPY clones/gochathub-webui/ ./
# Turnstile site key (public) is baked into the bundle; empty = no widget
ARG VITE_TURNSTILE_SITE_KEY=
ENV VITE_TURNSTILE_SITE_KEY=$VITE_TURNSTILE_SITE_KEY
RUN bun install && bun run build

FROM caddy:2
COPY Caddyfile /etc/caddy/Caddyfile
COPY --from=webui /src/dist /srv