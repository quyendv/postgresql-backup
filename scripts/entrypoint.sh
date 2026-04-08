#!/bin/bash
set -euo pipefail

MODE_LC="$(echo "${MODE:-backup}" | tr '[:upper:]' '[:lower:]')"
if [[ "${MODE_LC}" == "restore" ]]; then
    echo "[INFO] MODE=restore — running restore (one-shot)..."
    exec /usr/local/bin/restore.sh
fi

if [[ -n "${SCHEDULE:-}" ]]; then
    echo "[INFO] SCHEDULE='${SCHEDULE}' — starting in cron mode..."
    echo "${SCHEDULE} /usr/local/bin/backup.sh" > /tmp/backup-crontab
    exec supercronic /tmp/backup-crontab
else
    echo "[INFO] No SCHEDULE set — running backup once..."
    exec /usr/local/bin/backup.sh
fi
