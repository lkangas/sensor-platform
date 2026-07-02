#!/usr/bin/env bash
# One-command edge-node setup. Turns a blank Linux box into a live site.
#
#   usage: bootstrap-edge.sh <SITE> <MQTT_USER> [PROFILE: docker|binary]
#   MQTT password is read from $MQTT_PASS if set, otherwise prompted (never on argv).
#
# Idempotent: re-running pulls the latest repo and re-applies config.
set -euo pipefail

SITE="${1:?usage: bootstrap-edge.sh <SITE> <MQTT_USER> [docker|binary]}"
MQTT_USER="${2:?missing MQTT_USER (e.g. site-home)}"
PROFILE="${3:-docker}"
REPO_URL="${REPO_URL:-https://github.com/lkangas/sensor-platform.git}"
REPO_DIR="${REPO_DIR:-$HOME/sensor-platform}"

# --- password without exposing it on the command line ---
if [ -z "${MQTT_PASS:-}" ]; then
  read -rsp "MQTT password for ${MQTT_USER}: " MQTT_PASS; echo
fi
[ -n "$MQTT_PASS" ] || { echo "empty password, aborting" >&2; exit 1; }

# --- 1. repo ---
if [ -d "$REPO_DIR/.git" ]; then git -C "$REPO_DIR" pull --ff-only
else git clone "$REPO_URL" "$REPO_DIR"; fi
cd "$REPO_DIR/edge"

# --- 2. per-site .env (git-ignored) ---
umask 077
cat > .env <<EOF
SITE=$SITE
MQTT_HOST=${MQTT_HOST:-petzval.dy.fi}
MQTT_PORT=${MQTT_PORT:-8883}
MQTT_USER=$MQTT_USER
MQTT_PASS=$MQTT_PASS
GW_MAC=${GW_MAC:-00:00:00:00:00:00}
EOF

# --- 3. render config.yml from the template (git-ignored) ---
set -a; . ./.env; set +a
envsubst < ruuvi-go-gateway/config.yml.template > ruuvi-go-gateway/config.yml
echo "wrote edge/ruuvi-go-gateway/config.yml for site '$SITE'"

# --- 4. start, per profile ---
case "$PROFILE" in
  docker)
    command -v docker >/dev/null || { curl -fsSL https://get.docker.com | sh; sudo usermod -aG docker "$USER" || true; }
    sudo docker compose -f docker-compose.yml up -d
    echo "started via Docker. Logs: sudo docker compose -f $REPO_DIR/edge/docker-compose.yml logs -f"
    ;;
  binary)
    ARCH="$(uname -m)"   # armv6l, armv7l, aarch64, x86_64
    BIN="$REPO_DIR/edge/bin/ruuvi-gateway-$ARCH"
    [ -x "$BIN" ] || { echo "no prebuilt binary at $BIN — see docs/EDGE-SETUP.md (Profile A)"; exit 1; }
    sudo install -m 755 "$BIN" /usr/local/bin/ruuvi-go-gateway
    sudo install -d /etc/ruuvi-go-gateway
    sudo install -m 600 ruuvi-go-gateway/config.yml /etc/ruuvi-go-gateway/config.yml
    sudo install -m 644 systemd/ruuvi-gateway.service /etc/systemd/system/ruuvi-gateway.service
    sudo systemctl daemon-reload
    sudo systemctl enable --now ruuvi-gateway
    echo "started via systemd. Logs: sudo journalctl -u ruuvi-gateway -f"
    ;;
  *) echo "unknown profile '$PROFILE' (use docker|binary)" >&2; exit 1;;
esac

echo "done. On the VPS, confirm raw packets:  mosquitto_sub -t '$SITE/ruuvi/#'"
