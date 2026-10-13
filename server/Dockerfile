# syntax=docker/dockerfile:1
FROM swift:6.4-noble AS build

WORKDIR /build

# Preserve the parent package layout: the server links Core through ../.
# Native-engine builds with this manifest reject missing Linux app source paths.
# Keep the full source tree for robust parent package loading.
# GTK sources are present, but stay outside Core's build dependency closure.
COPY Package.swift Package.resolved ./
COPY Sources/ Sources/
COPY server/ server/

# SwiftPM caches dependencies and objects across builds. Copy the executable
# out in this same step because cache mounts are not retained in image layers.
# Swift 6.4's default Swift Build engine omits lib_FoundationICU,
# libCoreFoundation, lib_FoundationCollections, and lib_CFURLSessionInterface
# from static autolink, leaving undefined swift_u*/CFURLSession* symbols.
# The native engine emits the full autolink and keeps the .build/release layout.
# --build-system native is deprecated; remove it once swift-build links
# static Foundation correctly.
RUN --mount=type=cache,target=/build/server/.build \
    swift build --build-system native -c release --static-swift-stdlib \
        --package-path server --product monkeyspaw-server \
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
# tzdata makes the operator's TZ effective; stored timestamps remain UTC.
RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        tini ca-certificates libcurl4t64 libstdc++6 tzdata \
    && rm -rf /var/lib/apt/lists/* \
    && if id -u ubuntu >/dev/null 2>&1; then userdel --remove ubuntu; fi \
    && groupadd --gid 1000 monkeyspaw \
    && useradd --uid 1000 --gid 1000 --create-home --shell /usr/sbin/nologin monkeyspaw \
    && install -d -m 0700 -o monkeyspaw -g monkeyspaw /data

COPY --from=build /usr/local/bin/monkeyspaw-server /usr/local/bin/monkeyspaw-server

# Numeric Compose overrides must never start a privileged server. Ownership
# belongs to host provisioning, not a root entrypoint that repairs bind mounts.
COPY --chmod=755 <<'EOF' /usr/local/bin/monkeyspaw-entrypoint
#!/bin/sh
set -eu
if [ "$(id -u)" -eq 0 ]; then
    printf '%s\n' 'Refusing UID 0; set PUID to a non-root UID and prepare the host data directory.' >&2
    exit 1
fi
umask 077
exec /usr/local/bin/monkeyspaw-server "$@"
EOF

WORKDIR /data
USER 1000:1000

EXPOSE 8080

# Probe with the shipped CLI so the runtime needs no separate HTTP client.
HEALTHCHECK --interval=10s --timeout=5s --start-period=5s --retries=3 \
    CMD ["monkeyspaw-server", "healthcheck"]
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/monkeyspaw-entrypoint"]
CMD ["serve"]
