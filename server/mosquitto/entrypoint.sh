#!/bin/sh
# Wrapper entrypoint for eclipse-mosquitto: the 8883 TLS listener uses the same
# Let's Encrypt certificate Caddy obtains for petzval.dy.fi (shared caddy-data
# volume, mounted read-only at /caddy-data). Caddy stores the key root-only, and
# mosquitto drops to uid 1883 — so we copy the pair to /mosquitto/certs with the
# right ownership, then re-check every 12h and SIGHUP mosquitto when the cert
# renews (mosquitto reloads listener certificates on SIGHUP).
set -eu

DOMAIN="petzval.dy.fi"
DEST="/mosquitto/certs"

find_src() {
    # ACME CA directory name varies (letsencrypt / zerossl fallback) — glob it
    ls -d /caddy-data/caddy/certificates/*/"$DOMAIN" 2>/dev/null | head -1
}

sync_certs() {
    SRC=$(find_src) || return 1
    [ -n "$SRC" ] || return 1
    [ -f "$SRC/$DOMAIN.crt" ] && [ -f "$SRC/$DOMAIN.key" ] || return 1
    if ! cmp -s "$SRC/$DOMAIN.crt" "$DEST/server.crt" 2>/dev/null; then
        cp "$SRC/$DOMAIN.crt" "$DEST/server.crt"
        cp "$SRC/$DOMAIN.key" "$DEST/server.key"
        chown 1883:1883 "$DEST/server.crt" "$DEST/server.key"
        chmod 640 "$DEST/server.crt"
        chmod 600 "$DEST/server.key"
        return 0
    fi
    return 2   # unchanged
}

echo "certsync: waiting for Caddy's certificate for $DOMAIN ..."
until sync_certs; do
    [ $? -eq 2 ] && break   # already in place and current
    sleep 5
done
echo "certsync: certificate ready"

# periodic renewal check; HUP mosquitto if the cert rotated
(
    while true; do
        sleep 43200
        if sync_certs; then
            echo "certsync: certificate renewed, reloading mosquitto"
            kill -HUP "$(pidof mosquitto)" 2>/dev/null || true
        fi
    done
) &

# hand over to the stock image entrypoint (drops privileges itself)
exec /docker-entrypoint.sh mosquitto -c /mosquitto/config/mosquitto.conf
