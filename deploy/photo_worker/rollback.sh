#!/usr/bin/env bash
# d1-photo v2 — undo install.sh: stop + disable the worker, restore .env /
# manifest / unit from the backup dir install.sh printed. Model files and pip
# packages are left in place (harmless; nothing uses them without the worker).
#   bash deploy/photo_worker/rollback.sh ~/assisto/db_backups/photo_worker_<ts>
set -euo pipefail
BK=${1:?backup dir}
ROOT=/home/ubuntu/assisto
BE=$ROOT/backend
sudo systemctl disable --now assisto-photo-worker 2>/dev/null || true
[ -f "$BK/env.bak" ] && cp -a "$BK/env.bak" "$BE/.env"
[ -f "$BK/manifest.json.bak" ] && cp -a "$BK/manifest.json.bak" "$BE/core/photo_models/manifest.json"
if [ -f "$BK/unit.bak" ]; then
  sudo cp -a "$BK/unit.bak" /etc/systemd/system/assisto-photo-worker.service
else
  sudo rm -f /etc/systemd/system/assisto-photo-worker.service
fi
sudo systemctl daemon-reload
sudo systemctl restart assisto
# queued jobs keep their funds: they go back to "funded" so the phone can retry
cd "$BE" && "$ROOT/.venv/bin/python" manage.py shell -c "
from core.models import PhotoStudioJob, PhotoWorkItem
n = PhotoStudioJob.objects.filter(status__in=('queued','running')).update(status='funded')
PhotoWorkItem.objects.filter(state__in=('queued','running')).update(state='failed', error='rolled_back')
print('jobs back to funded:', n)"
echo "rolled back"
