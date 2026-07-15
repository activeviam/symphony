# syntax=docker/dockerfile:1.7

ARG ELIXIR_IMAGE=hexpm/elixir:1.19.5-erlang-28.5.0.3-alpine-3.23.5@sha256:c7d2a5f091d409d6d00367dc51dc64895c952157613aa0c8a4fbbd24172b6dfb

FROM ${ELIXIR_IMAGE} AS build

ENV MIX_ENV=prod
WORKDIR /build

RUN apk add --no-cache build-base ca-certificates git

RUN mix local.hex --force && mix local.rebar --force

COPY mix.exs mix.lock ./
RUN mix deps.get --only prod && mix deps.compile

COPY config ./config
COPY lib ./lib
COPY priv ./priv

RUN mix escript.build

FROM node:22-bookworm-slim@sha256:6c74791e557ce11fc957704f6d4fe134a7bc8d6f5ca4403205b2966bd488f6b3 AS codex

ARG CODEX_VERSION=0.144.2
RUN npm install --global "@openai/codex@${CODEX_VERSION}" \
  && codex --version \
  && case "$(uname -m)" in \
    aarch64) package="codex-linux-arm64"; triple="aarch64-unknown-linux-musl" ;; \
    x86_64) package="codex-linux-x64"; triple="x86_64-unknown-linux-musl" ;; \
    *) echo "Unsupported architecture: $(uname -m)" >&2; exit 1 ;; \
  esac \
  && install -d /opt/codex \
  && cp -a "/usr/local/lib/node_modules/@openai/codex/node_modules/@openai/${package}/vendor/${triple}/." /opt/codex/

FROM ${ELIXIR_IMAGE}

RUN apk add --no-cache \
    bash \
    ca-certificates \
    curl \
    git \
    github-cli \
    jq \
    openssh-client \
    openssl \
    ripgrep \
    tini \
  && addgroup -g 10001 -S symphony \
  && adduser -u 10001 -S -D -G symphony -h /home/symphony -s /bin/bash symphony \
  && mkdir -p \
    /etc/symphony \
    /var/log/symphony \
    /workspaces \
  && chown symphony:symphony \
    /etc/symphony \
    /var/log/symphony \
    /workspaces

COPY --from=codex /opt/codex /opt/codex
COPY --from=build /build/bin/symphony /usr/local/bin/symphony
COPY docker/entrypoint.sh /usr/local/bin/symphony-entrypoint
COPY docker/gh-wrapper.sh /usr/local/bin/gh
COPY docker/github-app-token.sh /usr/local/bin/github-app-token
COPY docker/review-watcher.sh /usr/local/bin/symphony-review-watcher

RUN ln -s /opt/codex/bin/codex /usr/local/bin/codex \
  && chmod 0755 \
    /usr/local/bin/gh \
    /usr/local/bin/github-app-token \
    /usr/local/bin/symphony \
    /usr/local/bin/symphony-entrypoint \
    /usr/local/bin/symphony-review-watcher

ENV CODEX_HOME=/home/symphony/.codex \
    HOME=/home/symphony \
    WORKFLOW_PATH=/etc/symphony/WORKFLOW.md

USER symphony
WORKDIR /workspaces

EXPOSE 8080

ENTRYPOINT ["/sbin/tini", "--", "/usr/local/bin/symphony-entrypoint"]
