#!/usr/bin/env bash
# Detect and repair a Meshtastic gateway that is "up" but passing no traffic.
#
# WHY THIS EXISTS
# ---------------
# Every liveness signal this stack has can be green while the gateway is dead,
# and it has now happened twice for different reasons:
#
#  2026-09-17, 79 hours. The BLE bridge broadcasts the node's stream to EVERY
#  TCP client, so mesh-api's configComplete landed while mqtt-proxy's own dump
#  was still in flight. The proxy marked a half-finished config as loaded, ran
#  with an empty channel table, and dropped every outbound packet "to prevent
#  loops". Units active, broker connected, radio busy, verify.sh passing.
#
#  2026-09-21, 3 hours. The node was power-cycled. The bridge retried 10 times
#  over ~10 minutes, logged "Failed to reconnect to BLE device after all
#  attempts", exited its polling loop - and KEPT RUNNING. Container up, unit
#  active, TCP still accepting clients, BLE gone permanently. Restart=always
#  cannot help because the process never exits.
#
# The first version of this script keyed only on "Dropping Node->MQTT" and was
# structurally blind to the second failure: an unconnected proxy drops nothing,
# so it logged "ok ... (uplinked=0)" three times while the gateway was dead.
# Absence of badness is not liveness. This version checks four signals.
#
# MISLEADING LOG LINES, for whoever reads this next:
#   "uplink_enabled=False for channel 'LongFast'" does NOT mean the node has
#   uplink disabled. It means "no channel by that name, so I assumed false" -
#   the channel table is empty. Check the node with `meshtastic --info`.
#   "MQTT Activity: Ns ago" counts INBOUND broker traffic. It keeps ticking
#   over happily while nothing whatsoever is being published.
#
# USAGE
#   systemd/quadlet (default): installed by scripts/deploy.sh, runs on a timer.
#   docker compose:            RESTART_MODE=compose CTR=docker COMPOSE_DIR=$PWD
set -uo pipefail

WINDOW="${WINDOW:-15m}"
RADIO_MAX="${RADIO_MAX:-3600}"           # seconds; radio quiet longer than this is suspect
CTR="${CTR:-podman}"                     # podman | docker
RESTART_MODE="${RESTART_MODE:-systemd}"  # systemd | compose
COMPOSE_DIR="${COMPOSE_DIR:-/opt/mesh-gateway}"
ENV_FILE="${ENV_FILE:-/etc/mesh-gateway/watchdog.env}"
# shellcheck disable=SC1090
[ -r "$ENV_FILE" ] && . "$ENV_FILE"
HC="${HC_PING_URL:-}"

log() { printf '%s [mesh-watchdog] %s\n' "$(date -Is)" "$*"; }

hc() {  # an alerting failure must never mask the real result
  [ -n "$HC" ] || return 0
  curl -fsS -m 10 --retry 3 "${HC}${1:-}" >/dev/null || log "WARN: healthchecks ping '${1:-/ok}' failed"
}

svc() {  # svc <start|stop|restart> <unit>
  case "$RESTART_MODE" in
    systemd) systemctl "$1" "$2" ;;
    compose) ( cd "$COMPOSE_DIR" && "$CTR" compose "$1" "$2" ) ;;
  esac
}

recreate_bridge() {
  # A plain restart reuses dead BLE session state; the container must be removed.
  case "$RESTART_MODE" in
    systemd) systemctl stop ble-bridge; sleep 2; "$CTR" rm -f ble-bridge >/dev/null 2>&1
             systemctl start ble-bridge ;;
    compose) ( cd "$COMPOSE_DIR" && "$CTR" compose rm -sf ble-bridge >/dev/null 2>&1
               "$CTR" compose up -d ble-bridge ) ;;
  esac
}

wait_for() {  # wait_for <container> <pattern> <max-seconds>
  local waited=0
  while [ "$waited" -lt "$3" ]; do
    "$CTR" logs "$1" 2>&1 | grep -aq "$2" && return 0
    sleep 5; waited=$((waited + 5))
  done
  return 1
}

# ── detection ────────────────────────────────────────────────────────────────
# A "Dropping Node->MQTT" line means a packet ARRIVED and was thrown away, so it
# cannot false-positive on a quiet mesh. The bridge give-up line is likewise
# unambiguous. Radio staleness is the positive-liveness check that the first
# version lacked.

bridge_gave_up() {
  # give-up must be more recent than the last successful connect; line numbers
  # order an append-only log without parsing timestamps.
  local ok dead
  ok=$("$CTR"  logs ble-bridge 2>&1 | grep -an 'Connected to BLE device' | tail -1 | cut -d: -f1)
  dead=$("$CTR" logs ble-bridge 2>&1 | grep -anE 'Failed to reconnect to BLE device after all attempts|exiting polling loop' | tail -1 | cut -d: -f1)
  [ -n "$dead" ] || return 1
  [ -n "$ok" ]   || return 0
  [ "$dead" -gt "$ok" ]
}

ble_down()     { "$CTR" logs --since "$WINDOW" ble-bridge 2>&1 | grep -q 'Cannot send to BLE - not connected'; }
proxy_looping(){ "$CTR" logs --since "$WINDOW" mqtt-proxy 2>&1 | grep -q 'Timed out waiting for connection completion'; }
# "Node->MQTT: Topic=" is logged for EVERY packet the proxy considers, INCLUDING
# ones it then drops - so it counts attempts, not successes. Actual uplinks are
# attempts minus drops.
#
# And drops are not automatically a fault. Meshtastic sends key-exchange traffic
# on a PKI channel that is not configured on the node; dropping an unknown
# channel is correct loop prevention. The outage signature is not "some drops",
# it is "everything dropped" - attempts > 0 with zero surviving.
drop_count()    { "$CTR" logs --since "$WINDOW" mqtt-proxy 2>&1 | grep -c 'Dropping Node->MQTT'; }
attempt_count() { "$CTR" logs --since "$WINDOW" mqtt-proxy 2>&1 | grep -c 'Node->MQTT: Topic='; }

radio_age() {  # echoes seconds since the last radio packet, or empty if unknown
  "$CTR" logs --tail 400 mqtt-proxy 2>&1 \
    | sed -n 's/.*Radio Activity:[[:space:]]*\([0-9][0-9]*\)s ago.*/\1/p' | tail -1
}

# ── repair ───────────────────────────────────────────────────────────────────
settle_and_report() {
  local up dr i
  local at
  for i in $(seq 1 24); do
    dr=$("$CTR" logs --since 3m mqtt-proxy 2>&1 | grep -c 'Dropping Node->MQTT')
    at=$("$CTR" logs --since 3m mqtt-proxy 2>&1 | grep -c 'Node->MQTT: Topic=')
    up=$(( at - dr )); [ "$up" -lt 0 ] && up=0
    [ "$at" -gt 0 ] && break
    sleep 5
  done
  if [ "${at:-0}" -gt 0 ] && [ "${up:-0}" -eq 0 ]; then
    log "FAILED: all ${at} packets still dropped after repair"; return 1; fi
  if [ "${at:-0}" -eq 0 ]; then
    log "INCONCLUSIVE: no packets at all in 120s - the mesh may be quiet, or the node is off"; return 0; fi
  log "repaired: uplinked=$up dropped=$dr of $at attempts"; return 0
}

repair_bridge() {
  log "repair(bridge): stopping clients, recreating ble-bridge"
  svc stop mesh-api; svc stop mqtt-proxy
  recreate_bridge
  if wait_for ble-bridge 'Connected to BLE device' 200; then
    log "  BLE reconnected"
  else
    log "  WARN: no BLE connection within 200s - the node itself may be off, or the adapter is wedged"
  fi
  svc start mqtt-proxy
  wait_for mqtt-proxy 'Node config fully loaded' 200 \
    && log "  proxy config loaded" || log "  WARN: proxy did not load config within 200s"
  svc start mesh-api
  settle_and_report
}

repair_proxy() {
  # mqtt-proxy must take its config dump with no other TCP client attached.
  log "repair(proxy): stopping mesh-api so mqtt-proxy gets an uncontended dump"
  svc stop mesh-api
  svc restart mqtt-proxy
  wait_for mqtt-proxy 'Node config fully loaded' 200 \
    && log "  proxy config loaded" || log "  WARN: proxy did not load config within 200s"
  svc start mesh-api
  settle_and_report
}

# ── main ─────────────────────────────────────────────────────────────────────
main() {
  [ -n "$HC" ] || log "note: HC_PING_URL unset in $ENV_FILE - repairs are log-only, nothing will page you"

  local drops attempts uplinks age reason="" mode=""
  drops=$(drop_count); attempts=$(attempt_count); age=$(radio_age)
  uplinks=$(( attempts - drops )); [ "$uplinks" -lt 0 ] && uplinks=0

  if bridge_gave_up; then
    reason="ble-bridge gave up reconnecting and is alive with no radio"; mode=bridge
  elif ble_down; then
    reason="ble-bridge reports 'Cannot send to BLE - not connected'";     mode=bridge
  elif [ "$attempts" -gt 0 ] && [ "$uplinks" -eq 0 ]; then
    reason="all $attempts packets dropped in $WINDOW (empty channel table)"; mode=proxy
  elif proxy_looping; then
    reason="mqtt-proxy stuck in a connect/timeout loop";                  mode=proxy
  elif [ -n "$age" ] && [ "$age" -gt "$RADIO_MAX" ]; then
    reason="no radio packet for ${age}s (limit ${RADIO_MAX}s)";           mode=bridge
  fi

  if [ -z "$mode" ]; then
    log "ok: uplinked=$uplinks dropped=$drops (of $attempts attempts) radio_age=${age:-unknown}s"
    hc
    return 0
  fi

  log "BROKEN: $reason (uplinked=$uplinks dropped=$drops radio_age=${age:-unknown}s)"
  hc /start
  if [ "$mode" = bridge ]; then repair_bridge; else repair_proxy; fi
  local rc=$?
  [ "$rc" -eq 0 ] && hc || hc /fail
  return "$rc"
}

# One watchdog at a time. -n so a slow repair does not queue runs behind itself.
exec 9>"${LOCK_FILE:-/run/mesh-uplink-watchdog.lock}"
flock -n 9 || { log "another watchdog run holds the lock, skipping"; exit 0; }
main "$@"
