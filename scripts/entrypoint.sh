#!/bin/bash
set -euo pipefail

if [[ -n "${SCHEDULE:-}" ]]; then
    echo "[INFO] SCHEDULE='${SCHEDULE}' — starting in cron mode..."
    echo "${SCHEDULE} /usr/local/bin/backup.sh" > /tmp/backup-crontab
    exec supercronic /tmp/backup-crontab
else
    echo "[INFO] No SCHEDULE set — running backup once..."
    exec /usr/local/bin/backup.sh
fi
