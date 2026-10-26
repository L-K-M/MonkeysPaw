# syntax=docker/dockerfile:1
FROM swift:6.4-noble AS build

# python3 runs the third-party notices generator and runtime check below.
RUN command -v python3 >/dev/null || { apt-get update \
        && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends python3 \
        && rm -rf /var/lib/apt/lists/*; }

WORKDIR /build

# Preserve the parent package layout: the server links Core through ../.
# Native-engine builds with this manifest reject missing Linux app source paths.
# Keep the full source tree for robust parent package loading.
# GTK sources are present, but stay outside Core's build dependency closure.
COPY Package.swift Package.resolved ./
COPY Sources/ Sources/
COPY server/ server/
# Notices generator, overrides and the license texts they name.
COPY scripts/swiftpm-notices.py scripts/static-runtime-notices.py scripts/
COPY scripts/licenses/ scripts/licenses/
COPY packaging/licenses/ICU-76.1-LICENSE.txt packaging/licenses/
COPY docs/licenses/UNICODE.txt docs/licenses/

# SwiftPM caches dependencies and objects across builds. Copy the executable
# out in this same step because cache mounts are not retained in image layers.
# Swift 6.4's default Swift Build engine omits lib_FoundationICU,
# libCoreFoundation, lib_FoundationCollections, and lib_CFURLSessionInterface
# from static autolink, leaving undefined swift_u*/CFURLSession* symbols.
# The native engine emits the full autolink and keeps the .build/release layout.
# --build-system native is deprecated; remove it once swift-build links
# static Foundation correctly.
# Notices for the statically linked pins (with their vendored BoringSSL and
# libyaml), Unicode tables, ICU and Swift runtime read the checkouts in the
# cache mount, so this step writes them too. Both scripts fail on a missing
# license text or an ICU version the notices do not name.
RUN --mount=type=cache,target=/build/server/.build \
    swift build --build-system native -c release --static-swift-stdlib \
        --package-path server --product monkeyspaw-server \
    && cp server/.build/release/monkeyspaw-server /usr/local/bin/monkeyspaw-server \
    && SWIFT_LICENSE="$(swift -print-target-info | python3 -c \
        'import json, sys; print(json.load(sys.stdin)["paths"]["runtimeResourcePath"])')/../../share/swift/LICENSE.txt" \
    && export SWIFT_LICENSE \
    && python3 -I scripts/swiftpm-notices.py --title monkeyspaw-server \
        --resolved server/Package.resolved --checkouts server/.build/checkouts \
        --overrides server/licenses/third-party-notices.json \
        --output /usr/local/share/doc/monkeyspaw-server/Third-Party-Notices.txt \
    && python3 -I scripts/static-runtime-notices.py check /usr/local/bin/monkeyspaw-server \
        --notices /usr/local/share/doc/monkeyspaw-server/Third-Party-Notices.txt

FROM ubuntu:noble AS runtime

ARG VERSION=dev REVISION=unknown CREATED=1970-01-01T00:00:00Z

# licenses: our code, every term in Third-Party-Notices.txt, and the packages
# installed below (tini MIT; ca-certificates GPL-2.0-or-later and MPL-2.0;
# libcurl4t64 curl; tzdata public domain; libstdc++6 is in ubuntu:noble).
# CI compares it with the notices (scripts/check-image-notices.sh).
LABEL org.opencontainers.image.title="Monkey's Paw Server" \
      org.opencontainers.image.description="Self-hosted prompt sync server for Monkey's Paw" \
      org.opencontainers.image.url="https://github.com/L-K-M/MonkeysPaw" \
      org.opencontainers.image.source="https://github.com/L-K-M/MonkeysPaw" \
      org.opencontainers.image.version=$VERSION \
      org.opencontainers.image.revision=$REVISION \
      org.opencontainers.image.created=$CREATED \
      org.opencontainers.image.licenses="Unlicense AND Apache-2.0 AND Apache-2.0 WITH Swift-exception AND GPL-2.0-or-later AND ISC AND MIT AND MPL-2.0 AND OpenSSL AND Unicode-3.0 AND curl"

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
# Notices for the code linked into the server, and the project's own license.
# System packages keep theirs in /usr/share/doc/<package>/copyright.
COPY --from=build /usr/local/share/doc/monkeyspaw-server/ /usr/share/doc/monkeyspaw-server/
COPY LICENSE /usr/share/doc/monkeyspaw-server/LICENSE

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
