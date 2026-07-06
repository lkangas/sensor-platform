#!/bin/sh
# Wrapper entrypoint for eclipse-mosquitto. The 8883 TLS listener reuses the
# Let's Encrypt certificate Caddy obtains for $MQTT_CERT_DOMAIN (the VPS public
# FQDN; shared caddy-data volume, mounted read-only at /caddy-data).
#
# The internal 1883 listener must NEVER depend on TLS: mosquitto starts
# immediately with the base config, and the 8883 listener is added via a
# runtime include (rt.d/) as soon as the certificate exists — then kept fresh
# by a 12h renewal check that SIGHUPs mosquitto (it reloads certs on HUP).
set -u

DOMAIN="${MQTT_CERT_DOMAIN:?MQTT_CERT_DOMAIN must be set (docker-compose passes it from PUBLIC_FQDN in server/.env)}"
DEST="/mosquitto/certs"
RTD="/mosquitto/rt.d"          # include_dir in mosquitto.conf; container-local
mkdir -p "$RTD"

find_src() {
    # ACME CA directory name varies (letsencrypt / zerossl fallback) — glob it
    ls -d /caddy-data/caddy/certificates/*/"$DOMAIN" 2>/dev/null | head -1
}

# returns 0 = copied (new/rotated), 1 = no cert available, 2 = unchanged
sync_certs() {
    SRC=$(find_src)
    [ -n "$SRC" ] && [ -f "$SRC/$DOMAIN.crt" ] && [ -f "$SRC/$DOMAIN.key" ] || return 1
    if ! cmp -s "$SRC/$DOMAIN.crt" "$DEST/server.crt" 2>/dev/null; then
        cp "$SRC/$DOMAIN.crt" "$DEST/server.crt"
        cp "$SRC/$DOMAIN.key" "$DEST/server.key"
        chown 1883:1883 "$DEST/server.crt" "$DEST/server.key"
        chmod 640 "$DEST/server.crt"
        chmod 600 "$DEST/server.key"
        return 0
    fi
    return 2
}

write_tls_conf() {
    cat > "$RTD/10-tls-listener.conf" <<EOF
listener 8883
allow_anonymous false
password_file /mosquitto/config/passwd
acl_file /mosquitto/config/acl
certfile /mosquitto/certs/server.crt
keyfile /mosquitto/certs/server.key
EOF
}

start_mosquitto() {
    mosquitto -c /mosquitto/config/mosquitto.conf &
    MPID=$!
}

trap 'kill -TERM "${MPID:-0}" 2>/dev/null; exit 0' TERM INT

sync_certs
rc=$?
if [ "$rc" != 1 ]; then
    write_tls_conf
    echo "certsync: certificate present — starting with 8883 enabled"
else
    echo "certsync: no certificate yet — starting 1883-only, will enable 8883 when Caddy has one"
fi
start_mosquitto

if [ "$rc" = 1 ]; then
    # phase 1: poll for first issuance, then restart with the TLS listener
    while :; do
        sleep 30
        kill -0 "$MPID" 2>/dev/null || { wait "$MPID"; exit $?; }   # broker died → let docker restart us
        if sync_certs; then
            echo "certsync: certificate arrived — enabling 8883"
            write_tls_conf
            kill -TERM "$MPID"; wait "$MPID" 2>/dev/null
            start_mosquitto
            break
        fi
    done
fi

# phase 2: liveness check every minute; renewal check every ~12h — HUP on rotation
TICKS=0
while :; do
    sleep 60 &
    SLEEP_PID=$!
    wait "$SLEEP_PID" 2>/dev/null
    kill -0 "$MPID" 2>/dev/null || { wait "$MPID"; exit $?; }   # broker died → exit, docker restarts us
    TICKS=$((TICKS + 1))
    if [ "$TICKS" -ge 720 ]; then
        TICKS=0
        if sync_certs; then
            echo "certsync: certificate renewed — reloading mosquitto"
            kill -HUP "$MPID" 2>/dev/null || true
        fi
    fi
done
