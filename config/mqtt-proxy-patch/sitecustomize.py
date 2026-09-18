"""Raise the meshtastic client's config-download deadline for this gateway.

CPython auto-imports this at startup (site.execsitecustomize) because the
mqtt-proxy unit puts this directory on PYTHONPATH. It is deliberately a
mounted file rather than a forked image: one number is the only delta we
need from upstream mqtt-proxy, and a fork hides that.

Why: meshtastic's stream_interface.connect() calls _waitConnected() with no
argument, so the wait is mesh_interface._waitConnected's hardcoded 30.0s
default. A clean config dump through this BLE bridge measured 28.8s on an
otherwise quiet link (2026-08-18, 178 known nodes, 97 frames) - 1.2s of
headroom. Any other client's want_config restarts the dump and blows through
it, which is what wedged the proxy in a 35s reconnect loop for 15 hours.
Upstream's own ble_interface.py already passes 60.0; this transport is BLE
*through* a bridge shared with two other clients, so it is slower still.

If the patch cannot be applied, exit instead of running unpatched: a silent
fallback here would read as "fixed" while the 30s loop continued.
"""
import os
import sys

WAIT_CONNECTED_SECS = 120.0

try:
    import inspect

    import meshtastic.mesh_interface as mesh_interface

    target = mesh_interface.MeshInterface._waitConnected
    # Guard against upstream growing more arguments: __defaults__ is positional,
    # so a changed signature would silently rewrite the wrong one.
    args = [p.name for p in inspect.signature(target).parameters.values()
            if p.name != "self"]
    if args != ["timeout"]:
        raise RuntimeError(f"unexpected _waitConnected signature: {args}")

    target.__defaults__ = (WAIT_CONNECTED_SECS,)
    applied = mesh_interface.MeshInterface._waitConnected.__defaults__[0]
    if applied != WAIT_CONNECTED_SECS:
        raise RuntimeError(f"default is {applied}, expected {WAIT_CONNECTED_SECS}")
    print(f"[sitecustomize] _waitConnected timeout {applied}s (was 30.0s)", flush=True)
except Exception as exc:
    sys.stderr.write(
        f"[sitecustomize] FATAL: could not raise _waitConnected timeout: {exc!r}\n")
    sys.stderr.flush()
    os._exit(70)
