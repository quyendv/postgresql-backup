ARG PG_VERSION=16

# ── Stage 1: Download and install AWS CLI ────────────────────────────────────
FROM debian:bookworm-slim AS aws-installer

RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    unzip \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

RUN ARCH=$(uname -m) && \
    if [ "$ARCH" = "aarch64" ]; then \
        AWS_URL="https://awscli.amazonaws.com/awscli-exe-linux-aarch64.zip"; \
    else \
        AWS_URL="https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip"; \
    fi && \
    curl -fsSL "$AWS_URL" -o awscliv2.zip && \
    unzip -q awscliv2.zip && \
    ./aws/install --install-dir /aws-cli-bin --bin-dir /aws-cli-bin/bin && \
    rm -rf awscliv2.zip aws/

# ── Stage 2: Final image ──────────────────────────────────────────────────────
FROM debian:bookworm-slim

ARG PG_VERSION=16
LABEL org.opencontainers.image.title="postgresql-backup"
LABEL org.opencontainers.image.description="PostgreSQL backup to S3-compatible storage"
LABEL org.opencontainers.image.source="https://github.com/quyendv/postgresql-backup"

RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    ca-certificates \
    gnupg \
    lsb-release \
    gzip \
    findutils \
    && rm -rf /var/lib/apt/lists/*

# Install PostgreSQL client matching the target server version
RUN curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc \
    | gpg --dearmor -o /usr/share/keyrings/postgresql.gpg \
    && echo "deb [signed-by=/usr/share/keyrings/postgresql.gpg] https://apt.postgresql.org/pub/repos/apt bookworm-pgdg main" \
    > /etc/apt/sources.list.d/pgdg.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends postgresql-client-${PG_VERSION} \
    && rm -rf /var/lib/apt/lists/*

COPY --from=aws-installer /aws-cli-bin /aws-cli-bin
ENV PATH="/aws-cli-bin/bin:$PATH"

COPY scripts/backup.sh /usr/local/bin/backup.sh
RUN chmod +x /usr/local/bin/backup.sh

ENV POSTGRES_HOST=""
ENV POSTGRES_PORT="5432"
ENV POSTGRES_USER="postgres"
ENV POSTGRES_PASSWORD=""
ENV POSTGRES_DB=""
ENV S3_ACCESS_KEY=""
ENV S3_SECRET_KEY=""
ENV S3_ENDPOINT=""
ENV S3_BUCKET=""
ENV S3_REGION="us-east-1"
ENV S3_PATH="backups"
ENV TTL_DAYS="7"
ENV BACKUP_DIR="/backup"

RUN mkdir -p /backup
VOLUME ["/backup"]

ENTRYPOINT ["/usr/local/bin/backup.sh"]
