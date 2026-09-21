#!/usr/bin/env bash
# Deploy the mesh-gateway stack to the host as podman quadlet units.
# Idempotent: re-running redeploys config and restarts the units.
set -euo pipefail

TARGET="${TARGET:-root@mesh-gw}"
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
UNITS=(ble-bridge mqtt-proxy mesh-api meshmonitor caddy)

echo "== preflight: host env file must exist (secrets never live in this repo)"
if ! ssh -o BatchMode=yes "$TARGET" 'test -s /etc/mesh-gateway/meshmonitor.env'; then
  echo "ERROR: /etc/mesh-gateway/meshmonitor.env missing on $TARGET."
  echo "Create it from config/meshmonitor.env.example (chmod 600) and re-run."
  exit 1
fi

echo "== copy quadlet units, Caddyfile, shim, udev rule"
scp -o BatchMode=yes -q "$REPO_DIR"/quadlet/*.container "$TARGET":/etc/containers/systemd/
scp -o BatchMode=yes -q "$REPO_DIR"/config/Caddyfile "$TARGET":/etc/mesh-gateway/Caddyfile
scp -o BatchMode=yes -q "$REPO_DIR"/shim/http_api_shim.py "$TARGET":/etc/mesh-gateway/http_api_shim.py
# mqtt-proxy runs the stock upstream image; this is its only delta (see the file).
ssh -o BatchMode=yes "$TARGET" mkdir -p /etc/mesh-gateway/mqtt-proxy-patch
scp -o BatchMode=yes -q "$REPO_DIR"/config/mqtt-proxy-patch/sitecustomize.py "$TARGET":/etc/mesh-gateway/mqtt-proxy-patch/sitecustomize.py
scp -o BatchMode=yes -q "$REPO_DIR"/host/81-disable-internal-bt.rules "$TARGET":/etc/udev/rules.d/
# Uplink watchdog + the readiness gate mesh-api.container calls as ExecStartPre.
# The stack can be fully "up" and passing no traffic at all; see the watchdog.
# The bridge keeps running with no radio after it gives up reconnecting; this
# wrapper is its entrypoint and exits so systemd can recreate the container.
scp -o BatchMode=yes -q "$REPO_DIR"/host/ble-bridge-entrypoint.sh "$TARGET":/etc/mesh-gateway/ble-bridge-entrypoint.sh
ssh -o BatchMode=yes "$TARGET" chmod +x /etc/mesh-gateway/ble-bridge-entrypoint.sh
scp -o BatchMode=yes -q "$REPO_DIR"/host/mesh-uplink-watchdog.sh "$TARGET":/usr/local/bin/mesh-uplink-watchdog.sh
scp -o BatchMode=yes -q "$REPO_DIR"/host/wait-for-mqtt-proxy-config.sh "$TARGET":/usr/local/bin/wait-for-mqtt-proxy-config.sh
ssh -o BatchMode=yes "$TARGET" chmod +x /usr/local/bin/mesh-uplink-watchdog.sh /usr/local/bin/wait-for-mqtt-proxy-config.sh
scp -o BatchMode=yes -q "$REPO_DIR"/host/mesh-uplink-watchdog.service "$TARGET":/etc/systemd/system/
scp -o BatchMode=yes -q "$REPO_DIR"/host/mesh-uplink-watchdog.timer "$TARGET":/etc/systemd/system/
# mDNS discovery for the mobile apps (no-op if avahi-daemon isn't installed)
scp -o BatchMode=yes -q "$REPO_DIR"/host/avahi-meshtastic.service "$TARGET":/etc/avahi/services/meshtastic.service

echo "== migrate: remove any non-systemd containers with our names, then start units"
ssh -o BatchMode=yes "$TARGET" bash -s <<'EOF'
set -euo pipefail
udevadm control --reload
systemctl daemon-reload
for name in ble-bridge mqtt-proxy mesh-api meshmonitor caddy; do
  # A container not created by our unit blocks the unit's ContainerName; remove it.
  if podman container exists "$name"; then
    unit=$(podman inspect "$name" --format '{{ index .Config.Labels "PODMAN_SYSTEMD_UNIT" }}' 2>/dev/null || true)
    if [ "$unit" != "${name}.service" ]; then
      echo "removing non-quadlet container: $name"
      podman rm -f "$name" >/dev/null
    fi
  fi
done
for name in ble-bridge mqtt-proxy mesh-api meshmonitor caddy; do
  # Masking a unit is how you keep an optional service off this host - most
  # often meshmonitor, which is a third TCP client on a bridge that starves at
  # three. `systemctl restart` on a masked unit FAILS, and this script runs
  # under `set -euo pipefail`, so an unguarded restart aborts the deploy partway
  # through: after the quadlet files are copied, before the units come back.
  if [ "$(systemctl is-enabled "${name}.service" 2>/dev/null)" = "masked" ]; then
    echo "skipping masked unit: ${name}.service (unmask it if you want it back)"
    continue
  fi
  systemctl restart "${name}.service"
done

systemctl enable --now mesh-uplink-watchdog.timer
echo "uplink watchdog timer enabled"
EOF

echo "== deployed. Run scripts/verify.sh next."
