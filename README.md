# postgresql-backup

Docker image to backup PostgreSQL databases to S3-compatible storage (MinIO, AWS S3, DigitalOcean Spaces, Cloudflare R2, etc.).

**Features:**

- `pg_dump` with custom format + gzip compression
- Upload to any S3-compatible storage via AWS CLI v2
- Automatic cleanup of old backups (local + remote) based on TTL
- Built-in cron scheduler via `supercronic` — no extra container needed
- Set `SCHEDULE` env to run periodically; omit to run once and exit
- Supports PostgreSQL 14 / 15 / 16 / 17
- Multi-arch: `linux/amd64` + `linux/arm64`
- Install once, run forever — no need to install anything on the host server

---

## Quickstart

### Run once (one-off backup)

```bash
docker run --rm \
  -e POSTGRES_HOST=192.168.1.100 \
  -e POSTGRES_PORT=5432 \
  -e POSTGRES_USER=postgres \
  -e POSTGRES_PASSWORD=secret \
  -e POSTGRES_DB=mydb \
  -e S3_ACCESS_KEY=xxx \
  -e S3_SECRET_KEY=xxx \
  -e S3_ENDPOINT=https://minio.example.com \
  -e S3_BUCKET=my-bucket \
  -e S3_REGION=us-east-1 \
  -e S3_PATH=backups/postgres \
  -e TTL_DAYS=7 \
  ghcr.io/quyendv/postgresql-backup:latest
```

### Run on a schedule (cron mode)

```bash
docker run -d \
  -e POSTGRES_HOST=192.168.1.100 \
  -e POSTGRES_PASSWORD=secret \
  -e POSTGRES_DB=mydb \
  -e S3_ACCESS_KEY=xxx \
  -e S3_SECRET_KEY=xxx \
  -e S3_ENDPOINT=https://minio.example.com \
  -e S3_BUCKET=my-bucket \
  -e SCHEDULE="0 */4 * * *" \
  --restart unless-stopped \
  ghcr.io/quyendv/postgresql-backup:latest
```

---

## Installation on Ubuntu

### Option A — Docker Compose (recommended, single container)

```bash
# 1. Clone repo
git clone https://github.com/quyendv/postgresql-backup.git
cd postgresql-backup

# 2. Configure environment
cp .env.example .env
nano .env   # fill in your values

# 3. Set SCHEDULE in docker-compose.yml (or override via .env)

# 4. Start
docker compose up -d

# 5. Check logs
docker compose logs -f postgres-backup
```

### Option B — Docker + System Crontab (no SCHEDULE env)

```bash
# 1. Pull image
docker pull ghcr.io/quyendv/postgresql-backup:latest

# 2. Create config directory
mkdir -p /opt/postgresql-backup
cd /opt/postgresql-backup

# 3. Create .env file
cp .env.example .env
nano .env   # fill in your values

# 4. Add to crontab (runs every 4 hours)
crontab -e
```

Add the following line to crontab:

```
0 */4 * * * docker run --rm --env-file /opt/postgresql-backup/.env -v postgresql_backup:/backup ghcr.io/quyendv/postgresql-backup:latest >> /var/log/postgresql-backup.log 2>&1
```

### Option C — Run manually (one-off)

```bash
docker compose run --rm postgres-backup
```

---

## Environment Variables

| Variable            | Required | Default     | Description                                                         |
| ------------------- | -------- | ----------- | ------------------------------------------------------------------- |
| `POSTGRES_HOST`     | ✅       | —           | PostgreSQL host                                                     |
| `POSTGRES_PORT`     | ✅       | `5432`      | PostgreSQL port                                                     |
| `POSTGRES_USER`     | ✅       | —           | Username                                                            |
| `POSTGRES_PASSWORD` | ✅       | —           | Password                                                            |
| `POSTGRES_DB`       | ✅       | —           | Database name                                                       |
| `S3_ACCESS_KEY`     | ✅       | —           | S3 access key                                                       |
| `S3_SECRET_KEY`     | ✅       | —           | S3 secret key                                                       |
| `S3_ENDPOINT`       | ✅       | —           | Endpoint URL (e.g. `https://minio.example.com`)                     |
| `S3_BUCKET`         | ✅       | —           | Bucket name                                                         |
| `S3_REGION`         | ✅       | `us-east-1` | Region                                                              |
| `S3_PATH`           | ✅       | `backups`   | Path prefix inside bucket                                           |
| `TTL_DAYS`          | ❌       | `7`         | Number of days to retain backups                                    |
| `BACKUP_DIR`        | ❌       | `/backup`   | Local backup directory inside container                             |
| `SCHEDULE`          | ❌       | _(empty)_   | Cron expression to run periodically. If empty, runs once and exits. |

### SCHEDULE examples

| Value         | Meaning                               |
| ------------- | ------------------------------------- |
| `0 */4 * * *` | Every 4 hours                         |
| `0 2 * * *`   | Daily at 02:00 UTC                    |
| `0 2 * * 0`   | Every Sunday at 02:00 UTC             |
| `@every 6h`   | Every 6 hours (supercronic extension) |
| _(empty)_     | Run once and exit                     |

---

## Docker Tags

| Tag           | PostgreSQL | Description       |
| ------------- | ---------- | ----------------- |
| `latest`      | 16         | Stable, PG16      |
| `pg14`        | 14         | PostgreSQL 14     |
| `pg15`        | 15         | PostgreSQL 15     |
| `pg16`        | 16         | PostgreSQL 16     |
| `pg17`        | 17         | PostgreSQL 17     |
| `v1.0.0-pg16` | 16         | Versioned release |

---

## Build Locally

```bash
# Build for PG16 (default)
docker build -t postgresql-backup:local .

# Build for PG14
docker build --build-arg PG_VERSION=14 -t postgresql-backup:pg14 .
```

---

## Kubernetes

See [`k8s/cronjob.yaml`](k8s/cronjob.yaml) — drop-in replacement for the old CronJob. No more AWS CLI installation on every run.

---

## Backup Structure on S3

```
s3://BUCKET/S3_PATH/
├── 20260305_020000/
│   └── postgresql_backup.dump.gz
├── 20260305_060000/
│   └── postgresql_backup.dump.gz
└── ...
```

---

## Restore

```bash
# Download from S3
aws s3 cp s3://BUCKET/S3_PATH/20260305_020000/postgresql_backup.dump.gz ./backup.dump.gz \
    --endpoint-url https://your-endpoint.com

# Decompress and restore
gunzip -c backup.dump.gz | pg_restore -h HOST -p 5432 -U USER -d TARGET_DB --no-owner
```
