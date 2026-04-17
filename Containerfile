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

ENV LANG=en_US.UTF-8
ENV LANGUAGE=en_US:en
ENV LC_ALL=en_US.UTF-8
ENV PHX_SERVER=true
ENV PHX_BIND=0.0.0.0

COPY --from=build /app/server/_build/prod/rel/termigate /app
COPY --chmod=0755 deploy/container-entrypoint.sh /app/entrypoint.sh

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD curl -f http://localhost:8888/healthz || exit 1

EXPOSE 8888

CMD ["/app/entrypoint.sh"]
