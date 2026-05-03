# Build stage
FROM docker.io/elixir:1.19-slim AS build

RUN apt-get update && apt-get install -y git nodejs npm && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app
ENV MIX_ENV=prod

# Install hex and rebar
RUN mix local.hex --force && mix local.rebar --force

COPY server/mix.exs server/mix.lock ./server/
RUN cd server && mix deps.get --only prod && mix deps.compile

COPY server/assets/package.json server/assets/package-lock.json ./server/assets/
RUN cd server/assets && npm ci

COPY server/ ./server/
RUN cd server && mix assets.deploy && mix release

# Runtime stage
FROM docker.io/debian:trixie-slim

RUN apt-get update && \
    apt-get install -y --no-install-recommends tmux locales curl && \
    rm -rf /var/lib/apt/lists/* && \
    sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen

# /bin/bash is the login shell because tmux invokes the user's login shell
# from /etc/passwd when spawning a pane. /usr/sbin/nologin would exit
# immediately, killing every pane — and with it the only window, the
# session, and ultimately the tmux daemon — the moment one is created.
RUN useradd --system --create-home --uid 10001 --shell /bin/bash termigate

# /var/lib/termigate is the canonical writable state directory in the
# image. Auth credentials and YAML config live here so they survive
# container recreation when this path is mounted as a persistent volume.
RUN install -d -o termigate -g termigate -m 0700 /var/lib/termigate

ENV LANG=en_US.UTF-8
ENV LANGUAGE=en_US:en
ENV LC_ALL=en_US.UTF-8
ENV PHX_SERVER=true
ENV PHX_BIND=0.0.0.0
ENV HOME=/home/termigate
# Keep auth + quick-action config on the persistent volume rather than
# the ephemeral $HOME-derived default. Without this, a container
# recreation would discard the admin account and reset to the first-run
# setup state.
ENV TERMIGATE_CONFIG_PATH=/var/lib/termigate/config.yaml

COPY --from=build --chown=termigate:termigate /app/server/_build/prod/rel/termigate /app
COPY --chmod=0755 --chown=termigate:termigate deploy/container-entrypoint.sh /app/entrypoint.sh

USER termigate
WORKDIR /home/termigate

VOLUME ["/var/lib/termigate"]

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD curl -f http://localhost:8888/healthz || exit 1

EXPOSE 8888

CMD ["/app/entrypoint.sh"]
