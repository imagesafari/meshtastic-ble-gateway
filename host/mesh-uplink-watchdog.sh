#!/usr/bin/env bash
# Detect and repair an mqtt-proxy that is "up" but uplinking nothing.
#
# WHY THIS EXISTS
# ---------------
# Every liveness signal this stack has can be green while the gateway is dead.
# It happened here for 79 hours: all five services running, BLE connected, radio
# packets arriving every few seconds, broker connected, "MQTT Connected: True"
# in every status block, and scripts/verify.sh passing throughout.
#
# mqtt-proxy decides per packet whether a channel may uplink by looking the
# topic's channel name up in the node config it loaded at startup. The BLE
# bridge broadcasts the node's stream to EVERY TCP client, so another client's
# configComplete can arrive while mqtt-proxy's own dump is still in flight. The
# proxy marks a half-finished config as loaded, ends up with an empty channel
# table, and then drops every outbound packet "to prevent loops" - which is the
# correct default for a genuinely unknown channel, and catastrophic when the
# reason it is unknown is that the config never arrived.
#
# The tell is unambiguous and has no quiet-mesh false positive: a "Dropping
# Node->MQTT" line means a packet DID arrive and was thrown away. A quiet mesh
# produces neither that line nor an uplink line.
#
# Two log messages actively mislead while this is happening:
#   * "uplink_enabled=False for channel 'LongFast'" sounds like the node has
#     uplink disabled. It does not. It means "no channel by that name, so I
#     assumed false". Check the node itself with `meshtastic --info`.
#   * "MQTT Activity: Ns ago" counts INBOUND broker traffic, so it keeps
#     ticking over while nothing at all is being published.
#
# USAGE
#   Quadlet/systemd (default):  install with scripts/deploy.sh, runs on a timer.
#   Docker Compose:             RESTART_MODE=compose COMPOSE_DIR=/path/to/repo \
#                               CTR=docker  mesh-uplink-watchdog.sh
#                               (drive it from cron or a systemd timer of your own)
set -uo pipefail

WINDOW="${WINDOW:-15m}"
CTR="${CTR:-podman}"                     # podman | docker
RESTART_MODE="${RESTART_MODE:-systemd}"  # systemd | compose
COMPOSE_DIR="${COMPOSE_DIR:-/opt/mesh-gateway}"
ENV_FILE="${ENV_FILE:-/etc/mesh-gateway/watchdog.env}"
# shellcheck disable=SC1090
[ -r "$ENV_FILE" ] && . "$ENV_FILE"
HC="${HC_PING_URL:-}"

log() { printf '%s [mesh-watchdog] %s\n' "$(date -Is)" "$*"; }

hc() {  # never let an alerting failure mask the real result
  [ -n "$HC" ] || return 0
  curl -fsS -m 10 --retry 3 "${HC}${1:-}" >/dev/null || log "WARN: healthchecks ping '${1:-/ok}' failed"
}

logs() { "$CTR" logs --since "$WINDOW" mqtt-proxy 2>&1; }

svc_stop()  { case "$RESTART_MODE" in
                systemd) systemctl stop "$1" ;;
                compose) ( cd "$COMPOSE_DIR" && "$CTR" compose stop "$1" ) ;;
              esac }
svc_start() { case "$RESTART_MODE" in
                systemd) systemctl start "$1" ;;
                compose) ( cd "$COMPOSE_DIR" && "$CTR" compose start "$1" ) ;;
              esac }
svc_restart() { case "$RESTART_MODE" in
                systemd) systemctl restart "$1" ;;
                compose) ( cd "$COMPOSE_DIR" && "$CTR" compose restart "$1" ) ;;
              esac }

# The ordered restart: mqtt-proxy must take its config dump with no other TCP
# client attached, or it can inherit a foreign configComplete all over again.
repair() {
  log "repairing: stopping mesh-api so mqtt-proxy gets an uncontended dump"
  svc_stop mesh-api

  log "restarting mqtt-proxy"
  svc_restart mqtt-proxy

  local i loaded=""
  for i in $(seq 1 40); do          # 40 * 5s = 200s; a clean dump measured 38.8s
    if "$CTR" logs mqtt-proxy 2>&1 | grep -q 'Node config fully loaded'; then loaded=1; break; fi
    sleep 5
  done
  [ -n "$loaded" ] || log "WARN: mqtt-proxy never logged 'Node config fully loaded' within 200s"

  local up=0 dr=0
  for i in $(seq 1 24); do          # up to 120s to see real traffic either way
    up=$("$CTR" logs --since 3m mqtt-proxy 2>&1 | grep -c 'Node->MQTT: Topic=')
    dr=$("$CTR" logs --since 3m mqtt-proxy 2>&1 | grep -c 'Dropping Node->MQTT')
    [ "$dr" -gt 0 ] && break
    [ "$up" -gt 0 ] && break
    sleep 5
  done

  log "restarting mesh-api"
  svc_start mesh-api

  if [ "$dr" -gt 0 ]; then
    log "FAILED: still dropping after repair (uplinked=$up dropped=$dr)"
    return 1
  fi
  if [ "$up" -eq 0 ]; then
    log "INCONCLUSIVE: no drops, but no uplink seen in 120s either (the mesh may simply be quiet)"
    return 0
  fi
  log "repaired: uplinked=$up dropped=$dr"
  return 0
}

main() {
  [ -n "$HC" ] || log "note: HC_PING_URL unset in $ENV_FILE - repairs are log-only, nothing will page you"

  local drops uplinks
  drops=$(logs | grep -c 'Dropping Node->MQTT')
  uplinks=$(logs | grep -c 'Node->MQTT: Topic=')

  if [ "$drops" -eq 0 ]; then
    log "ok: no dropped packets in the last $WINDOW (uplinked=$uplinks)"
    hc
    return 0
  fi

  log "BROKEN: $drops packets dropped in the last $WINDOW (uplinked=$uplinks)"
  hc /start
  if repair; then hc; return 0; fi
  hc /fail
  return 1
}

# One watchdog at a time. -n so a stuck repair does not queue runs behind itself.
exec 9>/run/mesh-uplink-watchdog.lock
flock -n 9 || { log "another watchdog run holds the lock, skipping"; exit 0; }
main "$@"
