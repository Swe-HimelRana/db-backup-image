# syntax=docker/dockerfile:1.7
FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive TZ=UTC
ARG TARGETARCH

# Base OS + clients (no extras)
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates curl gnupg \
    mysql-client \
    postgresql-client \
    redis-tools \
    s3cmd \
    # common tools
    bash tar gzip unzip \
  && rm -rf /var/lib/apt/lists/*

# MongoDB database tools (mongodump/mongorestore)
RUN curl -fsSL https://www.mongodb.org/static/pgp/server-7.0.asc \
    | gpg --dearmor -o /usr/share/keyrings/mongodb-server-7.0.gpg && \
    echo "deb [arch=amd64,arm64 signed-by=/usr/share/keyrings/mongodb-server-7.0.gpg] https://repo.mongodb.org/apt/ubuntu jammy/mongodb-org/7.0 multiverse" \
    > /etc/apt/sources.list.d/mongodb-org-7.0.list && \
    apt-get update && apt-get install -y --no-install-recommends mongodb-database-tools && \
    apt-get purge -y gnupg && apt-get autoremove -y && \
    rm -rf /var/lib/apt/lists/*

# rclone: pin a version and verify checksum
ARG RCLONE_VERSION=1.67.0
RUN set -eux; \
    case "$TARGETARCH" in \
      amd64) RCLONE_ARCH=amd64 ;; \
      arm64) RCLONE_ARCH=arm64 ;; \
      *) RCLONE_ARCH=amd64 ;; \
    esac; \
    cd /tmp; \
    curl -fsSLO "https://downloads.rclone.org/v${RCLONE_VERSION}/rclone-v${RCLONE_VERSION}-linux-${RCLONE_ARCH}.zip"; \
    curl -fsSLO "https://downloads.rclone.org/v${RCLONE_VERSION}/SHA256SUMS"; \
    grep "rclone-v${RCLONE_VERSION}-linux-${RCLONE_ARCH}.zip" SHA256SUMS | sha256sum -c -; \
    unzip "rclone-v${RCLONE_VERSION}-linux-${RCLONE_ARCH}.zip"; \
    install -m 0755 "rclone-v${RCLONE_VERSION}-linux-${RCLONE_ARCH}/rclone" /usr/local/bin/rclone; \
    rm -rf /tmp/*

# Create non-root user (idempotent)
ARG BACKUP_UID=10001
ARG BACKUP_GID=10001
RUN set -eux; \
    if ! getent group backup >/dev/null; then groupadd -g "${BACKUP_GID}" backup; fi; \
    if ! id -u backup >/dev/null 2>&1; then useradd -m -u "${BACKUP_UID}" -g "${BACKUP_GID}" -s /usr/sbin/nologin backup; fi; \
    mkdir -p /backup; \
    chown -R backup:backup /backup

# Labels (optional but recommended)
LABEL org.opencontainers.image.title="db-backup-toolbox" \
      org.opencontainers.image.description="Clients for MySQL/PostgreSQL/Redis/MongoDB with rclone & s3cmd for backups" \
      org.opencontainers.image.source="https://example.com/your-repo" \
      org.opencontainers.image.licenses="MIT"

# Add entrypoint script
COPY --chown=backup:backup backup.sh /usr/local/bin/backup.sh
RUN chmod +x /usr/local/bin/backup.sh

USER backup
WORKDIR /backup

# Default to one-shot backup; pass env vars to control behavior
ENTRYPOINT ["/usr/local/bin/backup.sh"]
