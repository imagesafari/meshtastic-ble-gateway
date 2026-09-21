#!/usr/bin/env bash
# Make ble-bridge FAIL LOUDLY instead of dying in place.
#
# THE PROBLEM
# The bridge stops trying to reach the node in two independent places:
#
#   core/ble_handler.py  MAX_RECONNECT_ATTEMPTS = 10   (class constant)
#       -> "Maximum reconnection attempts (10) exceeded. Giving up."
#   core/ble_handler.py  max_wait = 600                (local, in the poll loop)
#       -> "Reconnection failed after waiting, exiting polling loop"
#
# After either one the process KEEPS RUNNING. The container is up, the systemd
# unit is active, TCP 4403 still accepts clients, and there is no radio behind
# any of it. Restart=always cannot help, because nothing ever exits. On
# 2026-09-21 a two-minute node reboot cost three hours for exactly this reason.
#
# Only the first is a constant, so patching constants cannot fix this. The log
# output is the stable interface, so watch that: the moment the bridge says it
# has given up, kill it and exit non-zero. systemd then recreates the
# container, which is the recovery that actually works - a plain restart reuses
# dead BLE session state.
#
# Output is passed through unchanged, so `podman logs ble-bridge` is unaffected.
set -uo pipefail
# Job control, so the child becomes a process-group leader and we can signal the
# whole group. The bridge is a single python process today; killing only the
# recorded pid would leave any future child of it orphaned in the container.
set -m

FIFO="$(mktemp -u)"
mkfifo "$FIFO"

python -u -m cli.main "$@" > "$FIFO" 2>&1 &
PY=$!

# Signal the child's whole process group, falling back to the bare pid.
stop_child() {
  kill -"$1" -- -"$PY" 2>/dev/null || kill -"$1" "$PY" 2>/dev/null || true
}

# podman stop signals this wrapper (pid 1); pass it on rather than orphaning python
trap 'stop_child TERM' TERM INT

GAVE_UP=0
while IFS= read -r line; do
  printf '%s\n' "$line"
  case "$line" in
    *"Maximum reconnection attempts"*|\
    *"Failed to reconnect to BLE device after all attempts"*|\
    *"exiting polling loop"*)
      echo "[entrypoint] bridge reported it has stopped trying to reach the node."
      echo "[entrypoint] exiting non-zero so systemd recreates the container (a restart would reuse dead BLE session state)."
      GAVE_UP=1
      stop_child TERM
      break
      ;;
  esac
done < "$FIFO"

rm -f "$FIFO"

if [ "$GAVE_UP" -eq 1 ]; then
  for _ in 1 2 3 4 5; do kill -0 "$PY" 2>/dev/null || break; sleep 1; done
  stop_child KILL
  wait "$PY" 2>/dev/null
  exit 1
fi

wait "$PY"
exit $?
