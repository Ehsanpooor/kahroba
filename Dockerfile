# Splendor backend — Nakama Go runtime module.
#
# Nakama's Go runtime loads a compiled plugin, not source. The plugin must be
# built with the exact toolchain the server was built with, which is what the
# pluginbuilder image is for: the Go version, the nakama-common version and the
# server version all have to line up or the module is rejected at boot with a
# "plugin was built with a different version" error.
#
# Keep NAKAMA_VERSION identical in both stages, and keep nakama-common in
# runtime/go.mod on the version that ships with it (3.22.0 -> v1.32.0).
#
#   docker compose build && docker compose up -d
#
ARG NAKAMA_VERSION=3.22.0

# ---------- build the plugin ----------
FROM registry.heroiclabs.com/heroiclabs/nakama-pluginbuilder:${NAKAMA_VERSION} AS builder

ENV GOOS=linux
ENV CGO_ENABLED=1

WORKDIR /backend

# Dependencies first, so a source-only change does not re-download the module cache.
COPY runtime/go.mod runtime/go.sum ./
RUN go mod download

COPY runtime/ ./

# -trimpath keeps absolute build paths out of the artifact.
RUN go build -buildmode=plugin -trimpath -o ./splendor.so

# ---------- runtime image ----------
FROM registry.heroiclabs.com/heroiclabs/nakama:${NAKAMA_VERSION}

COPY --from=builder /backend/splendor.so /nakama/data/modules/splendor.so
