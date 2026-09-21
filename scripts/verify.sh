#!/usr/bin/env bash
# Verify the deployed stack end to end. Exits non-zero on the first failure.
set -euo pipefail

TARGET="${TARGET:-root@mesh-gw}"
HOST_IP="${HOST_IP:-192.0.2.10}"

fail() { echo "FAIL: $*" >&2; exit 1; }

echo "== systemd units"
for name in ble-bridge mqtt-proxy mesh-api meshmonitor caddy; do
  # Masking is how you keep an optional service off a host - meshmonitor most
  # often, being a third TCP client on a bridge that starves at three. That is
  # a deliberate choice, not a failure.
  enabled=$(ssh -o BatchMode=yes "$TARGET" systemctl is-enabled "${name}.service" 2>/dev/null || true)
  if [ "$enabled" = "masked" ]; then
    echo "  ${name}.service masked (deliberate, skipping)"
    continue
  fi
  state=$(ssh -o BatchMode=yes "$TARGET" systemctl is-active "${name}.service" || true)
  [ "$state" = "active" ] || fail "${name}.service is $state"
  echo "  ${name}.service active"
done

echo "== BLE link carrying traffic"
# Do not grep a fixed tail for "Connected to BLE device": that is a startup
# event, so the check breaks as soon as 50 lines of ordinary traffic push it out
# of the window, and then fails on a perfectly healthy bridge. Test the property
# we actually care about: the radio is delivering packets right now. mqtt-proxy
# prints "Radio Activity: Ns ago" in every 60s status block.
radio=$(ssh -o BatchMode=yes "$TARGET" \
  'podman logs --tail 200 mqtt-proxy 2>&1 | grep -a "Radio Activity:" | tail -1' || true)
secs=$(printf '%s' "$radio" | sed -n 's/.*Radio Activity:[[:space:]]*\([0-9][0-9]*\)s ago.*/\1/p')
[ -n "$secs" ] || fail "could not read 'Radio Activity' from mqtt-proxy (proxy down, or log format changed)"
[ "$secs" -lt 600 ] || fail "last radio packet was ${secs}s ago - BLE link is not delivering"
echo "  radio delivered a packet ${secs}s ago"

echo "== TCP 4403 reachable on host"
ssh -o BatchMode=yes "$TARGET" 'timeout 3 bash -c "</dev/tcp/127.0.0.1/4403"' || fail "TCP 4403 not accepting"
echo "  4403 accepting"

echo "== MQTT proxy attached and healthy (status prints every 60s; retrying up to 90s)"
proxy_ok=""
for i in 1 2 3 4 5 6 7 8 9; do
  if ssh -o BatchMode=yes "$TARGET" 'podman logs --tail 40 mqtt-proxy 2>&1' | grep -aq "MQTT Connected: True"; then
    proxy_ok=1; break
  fi
  sleep 10
done
[ -n "$proxy_ok" ] || fail "mqtt-proxy never reported MQTT Connected: True within 90s"
echo "  proxy reports broker connected"

echo "== MQTT uplink actually passing traffic"
# "MQTT Connected: True" above only proves the proxy reached the broker. It was
# true for all 79 hours of the outage this check was written for. The
# unambiguous failure signal is a drop line: a packet DID arrive from the radio
# and was thrown away because the proxy's channel table is empty. A quiet mesh
# produces neither line, so this cannot false-positive on low traffic.
# "Node->MQTT: Topic=" is logged for every packet considered, INCLUDING ones
# then dropped, so it counts attempts. Real uplinks are attempts minus drops.
# Some drops are correct: Meshtastic sends key-exchange traffic on a PKI channel
# that is not configured on the node, and dropping an unknown channel is proper
# loop prevention. The outage signature is everything dropped, not some.
drops=$(ssh -o BatchMode=yes "$TARGET" 'podman logs --since 15m mqtt-proxy 2>&1 | grep -c "Dropping Node->MQTT"' || true)
att=$(ssh -o BatchMode=yes "$TARGET" 'podman logs --since 15m mqtt-proxy 2>&1 | grep -c "Node->MQTT: Topic="' || true)
ups=$(( ${att:-0} - ${drops:-0} )); [ "$ups" -lt 0 ] && ups=0
if [ "${att:-0}" -gt 0 ] && [ "$ups" -eq 0 ]; then
  fail "all ${att} packets dropped in the last 15m - empty channel table. Run host/mesh-uplink-watchdog.sh"
fi
echo "  uplinked ${ups} of ${att:-0} attempts in the last 15m (${drops:-0} dropped, unknown channels are normal)"

echo "== uplink watchdog installed"
ssh -o BatchMode=yes "$TARGET" 'systemctl is-enabled mesh-uplink-watchdog.timer' >/dev/null \
  || fail "mesh-uplink-watchdog.timer is not enabled - nothing will notice the next silent uplink failure"
echo "  mesh-uplink-watchdog.timer enabled"

echo "== HTTPS UI (direct, internal CA)"
# Caddy reverse-proxies / to meshmonitor. When meshmonitor is masked on
# purpose, 502 is the correct answer and only proves the upstream is absent -
# so assert TLS terminates and Caddy answers, rather than a 200 that cannot
# happen in that configuration.
code=$(ssh -o BatchMode=yes "$TARGET" "curl -sk -o /dev/null -w '%{http_code}' https://$HOST_IP/")
if [ "$(ssh -o BatchMode=yes "$TARGET" systemctl is-enabled meshmonitor.service 2>/dev/null || true)" = "masked" ]; then
  [ -n "$code" ] && [ "$code" != "000" ] \
    || fail "https://$HOST_IP/ did not answer at all (curl code '$code') - Caddy or TLS is down"
  echo "  https://$HOST_IP/ -> $code (meshmonitor masked, so 502 here is expected)"
else
  [ "$code" = "200" ] || fail "https://$HOST_IP/ returned $code"
  echo "  https://$HOST_IP/ -> 200"
fi

echo "== HTTP-API shim"
code=$(ssh -o BatchMode=yes "$TARGET" "curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:4405/healthz")
[ "$code" = "200" ] || fail "shim /healthz returned $code (node link down or shim dead)"
echo "  shim healthy, node link up"

# Only meaningful if you publish these behind a reverse proxy. Opt in by
# setting the URLs; unset, this block is skipped rather than failing the run
# on a hostname that was only ever an example.
echo "== public names via your reverse proxy (set PUBLIC_SHIM_URL to enable)"
if [ -z "${PUBLIC_SHIM_URL:-}" ]; then
  echo "  PUBLIC_SHIM_URL unset, skipping"
else
  code=$(curl -s -m 8 -o /dev/null -w '%{http_code}' "$PUBLIC_SHIM_URL" || true)
  [ "$code" = "200" ] || fail "$PUBLIC_SHIM_URL returned '$code'"
  echo "  $PUBLIC_SHIM_URL -> 200"
fi
if [ -z "${PUBLIC_MESHMONITOR_URL:-}" ]; then
  echo "  PUBLIC_MESHMONITOR_URL unset, skipping"
elif [ "$(ssh -o BatchMode=yes "$TARGET" systemctl is-enabled meshmonitor.service 2>/dev/null || true)" = "masked" ]; then
  echo "  meshmonitor masked, skipping its public name"
else
  code=$(curl -s -m 8 -o /dev/null -w '%{http_code}' "$PUBLIC_MESHMONITOR_URL" || true)
  [ "$code" = "200" ] || fail "$PUBLIC_MESHMONITOR_URL returned '$code'"
  echo "  $PUBLIC_MESHMONITOR_URL -> 200"
fi

echo "ALL CHECKS PASSED"
