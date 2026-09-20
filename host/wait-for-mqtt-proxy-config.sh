#!/usr/bin/env bash
# Hold mesh-api's start until mqtt-proxy has finished downloading the node config.
#
# `After=mqtt-proxy.service` alone is not enough: a podman quadlet unit reports
# active the moment the container launches, but mqtt-proxy then spends ~40s
# pulling the node config over the BLE bridge. The bridge broadcasts the node
# stream to every TCP client, so a shim attaching during that window can make
# the proxy adopt a foreign configComplete, finish with an empty channel table,
# and silently drop every outbound packet from then on.
#
# This deliberately never fails closed. If the proxy is broken or slow, the web
# shim should still come up - a dead proxy must not also cost you the UI. The
# loud path for a broken proxy is mesh-uplink-watchdog.sh, not this script.
#
# Docker Compose has no equivalent hook. There, start mqtt-proxy first and wait
# for it before bringing the rest up; see the README.
set -uo pipefail

DEADLINE="${DEADLINE:-240}"
CTR="${CTR:-podman}"
STEP=5
waited=0

while [ "$waited" -lt "$DEADLINE" ]; do
  if "$CTR" logs mqtt-proxy 2>/dev/null | grep -q 'Node config fully loaded'; then
    echo "mqtt-proxy reported config loaded after ${waited}s; starting mesh-api"
    exit 0
  fi
  if ! systemctl is-active --quiet mqtt-proxy.service; then
    echo "mqtt-proxy.service is not active; starting mesh-api anyway rather than blocking the UI on it"
    exit 0
  fi
  sleep "$STEP"
  waited=$((waited + STEP))
done

echo "WARN: mqtt-proxy did not report 'Node config fully loaded' within ${DEADLINE}s." >&2
echo "WARN: starting mesh-api anyway; if the uplink is dead, mesh-uplink-watchdog will catch it." >&2
exit 0
