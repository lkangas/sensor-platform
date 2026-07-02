#!/usr/bin/env bash
# Pull a dashboard you edited/created in the browser back into the repo as
# provisioning JSON, ready to commit.
#
#   usage: scripts/grafana-pull-dashboard.sh <dashboard-uid> [outfile.json]
#
# Find the uid in the browser: open the dashboard, its URL is
#   https://petzval.dy.fi/d/<uid>/<slug>
# Default output file is server/grafana/provisioning/dashboards/<uid>.json
#
# Fetches via the Grafana API using the admin password from the VPS .env (never
# printed), and normalizes the JSON for provisioning: strips the internal DB id
# and version so the file is portable and re-provisions cleanly by uid. The
# datasource uid ("timescaledb") is preserved as-is because we pinned it — no
# "export for external sharing" templating needed.
set -euo pipefail

DASH_UID="${1:?usage: grafana-pull-dashboard.sh <dashboard-uid> [outfile.json]}"
SSH_TARGET="${SSH_TARGET:-lauri@petzval.dy.fi}"
REMOTE_DIR="${REMOTE_DIR:-\$HOME/sensor-platform/server}"
DASH_DIR="$(cd "$(dirname "$0")/.." && pwd)/server/grafana/provisioning/dashboards"

raw=$(ssh "$SSH_TARGET" "cd $REMOTE_DIR && set -a && . ./.env && set +a && \
  docker compose exec -T grafana curl -s \
  -u \"admin:\$GF_SECURITY_ADMIN_PASSWORD\" \
  http://localhost:3000/api/dashboards/uid/$DASH_UID")

norm=$(printf '%s' "$raw" | python3 -c '
import json, sys
resp = json.load(sys.stdin)
if "dashboard" not in resp:
    sys.exit("Grafana API error: " + json.dumps(resp)[:300])
d = resp["dashboard"]
d.pop("id", None)      # internal DB id — must not be pinned in provisioning
d.pop("version", None) # UI edit counter — let it float
print(json.dumps(d, indent=2))
')

out="${2:-$DASH_UID.json}"
case "$out" in /*) dest="$out";; *) dest="$DASH_DIR/$out";; esac
printf '%s\n' "$norm" > "$dest"
echo "wrote $dest"
echo "next: git add + commit + push, then on the VPS: git pull (provider hot-reloads in ~30s)"
