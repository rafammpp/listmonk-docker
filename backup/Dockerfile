FROM debian:bookworm-slim

ARG SUPERCRONIC_VERSION=v0.2.38

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        age \
        awscli \
        ca-certificates \
        curl \
        gzip \
        postgresql-client \
        tzdata \
    && rm -rf /var/lib/apt/lists/*

RUN set -eu; \
    arch="$(dpkg --print-architecture)"; \
    case "$arch" in \
        amd64) supercronic_arch=amd64 ;; \
        arm64) supercronic_arch=arm64 ;; \
        *) echo "Unsupported architecture: $arch" >&2; exit 1 ;; \
    esac; \
    curl -fsSL -o /usr/local/bin/supercronic "https://github.com/aptible/supercronic/releases/download/${SUPERCRONIC_VERSION}/supercronic-linux-${supercronic_arch}"; \
    chmod +x /usr/local/bin/supercronic

COPY backup-and-upload.sh /usr/local/bin/backup-and-upload.sh
COPY restore-from-r2.sh /usr/local/bin/restore-from-r2.sh
COPY entrypoint.sh /usr/local/bin/entrypoint.sh

RUN chmod +x /usr/local/bin/backup-and-upload.sh /usr/local/bin/restore-from-r2.sh /usr/local/bin/entrypoint.sh \
    && mkdir -p /backups

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]