# postgresql-backup

Docker image to backup PostgreSQL databases to S3-compatible storage (MinIO, AWS S3, DigitalOcean Spaces, Cloudflare R2, etc.).

**Features:**

- `pg_dump` with custom format + gzip compression
- Upload to any S3-compatible storage via AWS CLI v2
- Automatic cleanup of old backups (local + remote) based on TTL, with optional minimum count of newest backups always kept
- Built-in cron scheduler via `supercronic` — no extra container needed
- Set `SCHEDULE` env to run periodically; omit to run once and exit
- One-shot **restore** from S3 with `MODE=restore` (same image as backup)
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

### Restore once (from S3)

Use the **same** image tag as your PostgreSQL major version (e.g. `pg17` for PostgreSQL 17). The dump on S3 must be `postgresql_backup.dump.gz` under `S3_PATH/<timestamp>/` (same layout as backup).

```bash
docker run --rm \
  -e MODE=restore \
  -e POSTGRES_HOST=192.168.1.100 \
  -e POSTGRES_PORT=5432 \
  -e POSTGRES_USER=postgres \
  -e POSTGRES_PASSWORD=secret \
  -e POSTGRES_DB=mydb \
  -e RESTORE_DROP_DB=true \
  -e S3_ACCESS_KEY=xxx \
  -e S3_SECRET_KEY=xxx \
  -e S3_ENDPOINT=https://minio.example.com \
  -e S3_BUCKET=my-bucket \
  -e S3_REGION=us-east-1 \
  -e S3_PATH=backups/postgres \
  ghcr.io/quyendv/postgresql-backup:pg16
```

- Without `RESTORE_DROP_DB=true`, the target database must already exist.
- Set `RESTORE_TIMESTAMP=YYYYMMDD_HHMMSS` to pick a specific backup folder; otherwise the **latest** folder matching `YYYYMMDD_*` under `S3_PATH/` is used.
- Set `RESTORE_CLEAN=true` to add `pg_restore --clean --if-exists` (drops objects in the target DB before restore).

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
| `MIN_BACKUPS`       | ❌       | `0`         | Always keep this many **newest** backups (local + S3), even past TTL |
| `BACKUP_DIR`        | ❌       | `/backup`   | Local backup directory inside container                             |
| `SCHEDULE`          | ❌       | _(empty)_   | Cron expression to run periodically. If empty, runs once and exits. |
| `MODE`              | ❌       | `backup`    | Set to `restore` to run restore instead of backup (ignores `SCHEDULE`). |

#### Restore-only variables

| Variable                   | Required | Default   | Description |
| -------------------------- | -------- | --------- | ----------- |
| `RESTORE_TIMESTAMP`      | ❌       | _(latest)_ | Backup folder name under `S3_PATH` (e.g. `20260305_020000`). Omit to use newest `YYYYMMDD_*` prefix. |
| `RESTORE_DROP_DB`        | ❌       | `false`   | If `true`, terminate connections, `DROP DATABASE`, then `CREATE DATABASE` for `POSTGRES_DB` (uses `POSTGRES_MAINTENANCE_DB`). |
| `POSTGRES_MAINTENANCE_DB` | ❌       | `postgres` | Database to connect to for drop/create when `RESTORE_DROP_DB=true`. |
| `RESTORE_CLEAN`          | ❌       | `false`   | If `true`, pass `--clean --if-exists` to `pg_restore`. |
| `RESTORE_WORK_DIR`       | ❌       | `/tmp/postgresql-restore` | Temp directory for the downloaded `.dump.gz`. |

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

- [`k8s/cronjob.yaml`](k8s/cronjob.yaml) — scheduled backup (same image; no AWS CLI install per run).
- [`k8s/restore-job.yaml`](k8s/restore-job.yaml) — example **Job** with `MODE=restore` and a Secret aligned with backup env names.

See also [`scripts/demo-restore.yaml`](scripts/demo-restore.yaml) for a minimal Pod + Service + restore Job demo.

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

## Restore (manual / outside the image)

If you prefer not to use `MODE=restore`:

```bash
aws s3 cp s3://BUCKET/S3_PATH/20260305_020000/postgresql_backup.dump.gz ./backup.dump.gz \
    --endpoint-url https://your-endpoint.com

gunzip -c backup.dump.gz | pg_restore -h HOST -p 5432 -U USER -d TARGET_DB --no-owner --no-privileges
```

The image’s restore mode downloads this same object and runs `pg_restore` with a compatible client version.
