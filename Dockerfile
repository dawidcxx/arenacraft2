# syntax=docker/dockerfile:1

# ---------------------------------------------------------------------------
# Build stage
#
# Compiles the static arenacraft2 server binary with the pinned Zig toolchain.
# Alpine is used as the builder so the binary targets musl and is fully static,
# which lets the tiny Alpine runtime below run it as-is (no shared libraries).
# ---------------------------------------------------------------------------
FROM alpine:3.20 AS builder

ARG TARGETARCH
ARG ZIG_VERSION=0.16.0

WORKDIR /app

RUN apk add --no-cache curl tar xz git

# Install the pinned Zig toolchain for the platform being built.
RUN case "${TARGETARCH}" in \
      amd64) zarch=x86_64 ;; \
      arm64) zarch=aarch64 ;; \
      *) echo "unsupported TARGETARCH: ${TARGETARCH}" >&2; exit 1 ;; \
    esac \
    && curl -fsSL "https://ziglang.org/download/${ZIG_VERSION}/zig-${zarch}-linux-${ZIG_VERSION}.tar.xz" -o /tmp/zig.tar.xz \
    && mkdir -p /opt/zig \
    && tar -xJf /tmp/zig.tar.xz -C /opt \
    && mv "/opt/zig-${zarch}-linux-${ZIG_VERSION}" /opt/zig/current \
    && ln -s /opt/zig/current/zig /usr/local/bin/zig \
    && rm /tmp/zig.tar.xz \
    && echo "${zarch}-linux-musl" > /tmp/zig-target \
    && zig version

# Copy build manifest and sources.
COPY build.zig build.zig.zon ./
COPY src ./src

# Build the release server. Targeting musl keeps the runtime layer dependency
# free and allows running on the minimal Alpine base below.
RUN zig build --release=fast -Dtarget="$(cat /tmp/zig-target)" server-build

# ---------------------------------------------------------------------------
# Runtime stage
#
# Minimal Alpine image running the static server binary. A single binary runs
# both the Auth (realmlist) and the World server, so both ports are exposed.
# ---------------------------------------------------------------------------
FROM alpine:3.20

RUN apk add --no-cache ca-certificates \
    && addgroup -S arenacraft \
    && adduser -S arenacraft -G arenacraft

COPY --from=builder /app/zig-out/bin/arenacraft2 /usr/local/bin/arenacraft2

ENV DATABASE_URL=postgresql://arenacraft:arenacraft@127.0.0.1:5432/arenacraft

# Auth server (realmlist / logon endpoint).
EXPOSE 3724
# World server (game client connection endpoint).
EXPOSE 8085

USER arenacraft

CMD ["arenacraft2"]
