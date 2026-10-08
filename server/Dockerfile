# syntax=docker/dockerfile:1
FROM swift:6.4-noble AS build

WORKDIR /build

# Preserve the parent package layout: the server links Core through ../.
# No GTK sources or system headers belong in this dependency closure.
COPY Package.swift Package.resolved ./
COPY Sources/MonkeysPawCore/ Sources/MonkeysPawCore/
COPY server/ server/

# SwiftPM caches dependencies and objects across builds. Copy the executable
# out in this same step because cache mounts are not retained in image layers.
RUN --mount=type=cache,target=/build/server/.build \
    swift build -c release --static-swift-stdlib --package-path server \
        --product monkeyspaw-server \
    && cp server/.build/release/monkeyspaw-server /usr/local/bin/monkeyspaw-server

FROM ubuntu:noble AS runtime

ARG VERSION=dev REVISION=unknown CREATED=1970-01-01T00:00:00Z

LABEL org.opencontainers.image.title="Monkey's Paw Server" \
      org.opencontainers.image.description="Self-hosted prompt sync server for Monkey's Paw" \
      org.opencontainers.image.url="https://github.com/L-K-M/MonkeysPaw" \
      org.opencontainers.image.source="https://github.com/L-K-M/MonkeysPaw" \
      org.opencontainers.image.version=$VERSION \
      org.opencontainers.image.revision=$REVISION \
      org.opencontainers.image.created=$CREATED \
      org.opencontainers.image.licenses="Unlicense"

ENV MONKEYSPAW_VERSION=$VERSION

# tini forwards shutdown signals and reaps children. FoundationNetworking and
# ICU still link the curl and C++ runtimes dynamically with static Swift.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        tini ca-certificates libcurl4t64 libstdc++6 \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --system --create-home --user-group monkeyspaw \
    && install -d -o monkeyspaw -g monkeyspaw /data

COPY --from=build /usr/local/bin/monkeyspaw-server /usr/local/bin/monkeyspaw-server

WORKDIR /data
USER monkeyspaw

EXPOSE 8080

# Probe with the shipped CLI so the runtime needs no separate HTTP client.
HEALTHCHECK --interval=10s --timeout=5s --start-period=5s --retries=3 \
    CMD ["monkeyspaw-server", "healthcheck"]
ENTRYPOINT ["/usr/bin/tini", "--", "monkeyspaw-server"]
CMD ["serve"]
