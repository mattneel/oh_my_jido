# Build from the repository root: docker build -f examples/docs_site/Dockerfile .
# Official multi-platform Elixir1.20.2/OTP28 index, inspected 2026-10-19.
ARG BUILDER_IMAGE=elixir:1.20.2-otp-28@sha256:edd3098f7f3e0d03f8cfd408364ee8b67f4dca35b0ee7273f7cae9f16c4f71f6
FROM ${BUILDER_IMAGE} AS builder
RUN apt-get update && apt-get install -y --no-install-recommends build-essential git ca-certificates && rm -rf /var/lib/apt/lists/*
ENV MIX_ENV=prod
WORKDIR /src
COPY mix.exs mix.lock ./
COPY lib ./lib
COPY priv ./priv
COPY vendor ./vendor
COPY examples/docs_site ./examples/docs_site
WORKDIR /src/examples/docs_site
RUN mix local.hex --force && mix local.rebar --force && mix deps.get --only prod
RUN mix deps.compile && mix compile --warnings-as-errors
RUN mix assets.setup && mix assets.deploy && mix release --overwrite

FROM debian:trixie-slim AS runner
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates libstdc++6 openssl libncurses6 libatomic1 && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY --from=builder --chown=65534:65534 /src/examples/docs_site/_build/prod/rel/oh_my_jido_docs ./
ENV LANG=C.UTF-8 PHX_SERVER=true DOCS_EDITOR_ENABLED=0 RELEASE_DISTRIBUTION=none PORT=8080
USER 65534:65534
EXPOSE 8080
CMD ["/app/bin/oh_my_jido_docs", "start"]
