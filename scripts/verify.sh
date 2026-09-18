#!/usr/bin/env bash
# Verify the deployed stack end to end. Exits non-zero on the first failure.
set -euo pipefail

TARGET="${TARGET:-root@mesh-gw}"
HOST_IP="${HOST_IP:-192.0.2.10}"

fail() { echo "FAIL: $*" >&2; exit 1; }

echo "== systemd units"
for name in ble-bridge mqtt-proxy mesh-api meshmonitor caddy; do
  state=$(ssh -o BatchMode=yes "$TARGET" systemctl is-active "${name}.service" || true)
  [ "$state" = "active" ] || fail "${name}.service is $state"
  echo "  ${name}.service active"
done

echo "== BLE link"
ssh -o BatchMode=yes "$TARGET" 'podman logs --tail 50 ble-bridge 2>&1' | grep -aq "Connected to BLE device" \
  || fail "ble-bridge has no recent BLE connection in its log tail"
echo "  bridge log shows BLE connected"

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

echo "== HTTPS UI (direct, internal CA)"
code=$(ssh -o BatchMode=yes "$TARGET" "curl -sk -o /dev/null -w '%{http_code}' https://$HOST_IP/")
[ "$code" = "200" ] || fail "https://$HOST_IP/ returned $code"
echo "  https://$HOST_IP/ -> 200"

echo "== HTTP-API shim"
code=$(ssh -o BatchMode=yes "$TARGET" "curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:4405/healthz")
[ "$code" = "200" ] || fail "shim /healthz returned $code (node link down or shim dead)"
echo "  shim healthy, node link up"

echo "== public names via NPM (proxy hosts 74/75 on docker-nginx)"
code=$(curl -s -m 8 -o /dev/null -w '%{http_code}' "https://mesh-gw.example.com/healthz")
[ "$code" = "200" ] || fail "https://mesh-gw.example.com/healthz returned $code"
echo "  https://mesh-gw.example.com/healthz -> 200"
code=$(curl -s -m 8 -o /dev/null -w '%{http_code}' "https://meshmonitor.example.com/")
[ "$code" = "200" ] || fail "https://meshmonitor.example.com/ returned $code"
echo "  https://meshmonitor.example.com/ -> 200"

echo "ALL CHECKS PASSED"
