# meshtastic-ble-gateway

> **Note:** this is 100% vibecoded. It works great for me, but your mileage may
> vary. Proceed accordingly.

**Turn a Meshtastic node with no network hardware into a full MQTT gateway and a
browser-reachable radio — over Bluetooth.**

The best-placed node in a mesh is usually the worst-connected one: on a roof,
solar-powered, and if it's an nRF52 board, without any network interface at all.

The usual workaround is to run the MQTT gateway on a lesser indoor node. That
works, and it ruins your topology data — every packet arrives at the broker
stamped with the indoor node as gateway and last hop, so you can no longer see
what the high node actually heard directly. You end up with a map of the wrong
radio.

This is the way out. A Linux box holds a permanent BLE connection to the high
node and lends it a network stack, without changing who the gateway *is*.

![A Meshtastic web client driving the node over the BLE bridge: live packet capture,
heard-via topology and per-node signal history](docs/img/web-client-connected.png)

*A Meshtastic web client connected to the HTTP shim.*

## What you get

1. **An MQTT gateway with true topology.** Meshtastic firmware's *MQTT Client
   Proxy* makes the radio build each MQTT message itself — topic,
   ServiceEnvelope, and its own node id as `gateway_id`. The attached client
   publishes those bytes verbatim. The result is byte-identical to what a native
   WiFi gateway on that node would have sent, with real last-hop data intact.

2. **A browser-reachable radio.** The node's TCP protocol is re-exposed on the
   LAN for phone apps and the CLI, and a small HTTP-API shim translates it so a
   hosted web client can connect over HTTPS.

## How it fits together

```
   solar node  (nRF52 + SX1262, roof, no WiFi)
        │
        │  BLE — one link, held open 24/7
        ▼
 ┌─────────────────── Linux host ────────────────────┐
 │  ble-bridge   BLE  ->  Meshtastic TCP :4403       │
 │  mqtt-proxy   :4403 -> your MQTT broker           │
 │  mesh-api     :4403 -> node HTTP API on :4405     │
 │  meshmonitor  :3001  web UI            (optional) │
 │  caddy        :443   HTTPS, internal CA (optional)│
 └───────────────────────────────────────────────────┘
        │                          │
        ▼                          ▼
   MQTT broker              browsers, phone apps, CLI
   gateway_id = the solar node, not this host
```

## Requirements

- A Meshtastic node with BLE. nRF52 preferred; ESP32 works, but mind the power
  draw if it's solar.
- **A Linux host** within BLE range (roughly 10–30 m through structure), with
  Docker. Docker Desktop on macOS/Windows cannot do this — containers run in a VM
  with no access to your Bluetooth adapter.
- A USB Bluetooth adapter is worth it. If the host has more than one radio,
  disable the ones you don't want (see `host/81-disable-internal-bt.rules`).
- An MQTT broker, if you want the gateway half. The browser half works without one.

**Battery cost of a permanent BLE link: about 1%.** The LoRa radio's always-on
receive dominates at 5–12 mA; BLE adds 0.02–0.5 mA. A solar node does not notice.

## Quick start

```bash
git clone https://github.com/imagesafari/meshtastic-ble-gateway
cd meshtastic-ble-gateway

# 1. Pair the node, once. Nothing else may hold its single BLE slot -
#    close the phone app first. Screenless nodes default to PIN 123456.
#    Edit the MAC and PIN at the top of the script, then:
expect host/pair-node.exp

# 2. Configure
cp .env.example .env         # set NODE_BLE_MAC at minimum

# 3. Run
docker compose up -d
docker compose logs -f ble-bridge
```

Then point a client at it:

- **CLI** — `meshtastic --host <your-host>`
- **Phone app** — add a TCP device at `<your-host>:4403`
- **Web client** — any Meshtastic web client's HTTP transport, pointed at
  `http://<your-host>:4405` (set `ALLOW_ORIGINS` in `.env` first)

Optional pieces are behind Compose profiles, off by default:

```bash
docker compose --profile with-meshmonitor up -d    # web UI on :3001
docker compose --profile with-caddy up -d          # HTTPS on a bare IP
```

## Configure MQTT on the node, not here

This trips everyone up: **the proxy reads the broker address, credentials, and
which channels uplink from the node itself.** None of it is container config.

Over the bridge once it's running, or from the phone app first:

```bash
meshtastic --host <your-host> --set mqtt.enabled true
meshtastic --host <your-host> --set mqtt.proxy_to_client_enabled true
meshtastic --host <your-host> --set mqtt.address <broker>
meshtastic --host <your-host> --set mqtt.username <user>
meshtastic --host <your-host> --set mqtt.password <pass>
meshtastic --host <your-host> --ch-index 0 --ch-set uplink_enabled true
```

Restart `mqtt-proxy` after changing node config — it caches what it read when it
attached.

## How many clients can attach — read this one

**Two TCP clients work. Three livelock.**

When a client attaches it requests a full config dump. Through a BLE bridge that
dump takes roughly **30-40 seconds**, against a 30-second deadline hardcoded in
the meshtastic Python library — and it grows with the size of your mesh. It
measured 28.8s on a mesh of 178 known nodes and 38.8s a month later on the same
hardware, so the stock deadline is now missed outright: even the bundled
`meshtastic` CLI times out. `config/mqtt-proxy-patch/` exists for this. Any
second client requesting config also restarts the dump for everyone.

With three, nobody ever finishes. Every client ends up with an empty channel
table, and `mqtt-proxy` then rejects every message as
`Channel 'LongFast' not found in node config` — for a channel that is certainly
configured — and drops 100% of uplinks.

**The failure is invisible.** The proxy reports itself connected with a live
radio. Web clients still show mesh traffic, because packets need no channel
table. We ran like that for 9.8 days: 7,076 messages received, 7,076 dropped,
zero published.

Budget two TCP clients:

| Client | Cost |
|---|---|
| `mqtt-proxy` | 1 slot |
| `mesh-api` | 1 slot — **for all browsers combined** |
| MeshMonitor | 1 slot |
| Phone app / CLI | 1 slot each |

Browser clients are free because `mesh-api` holds one connection and fans frames
out to a queue per client. Ten tabs cost one slot. Anything speaking raw TCP
costs its own. This is why MeshMonitor is behind a profile and off by default.

## Two clients are not automatically safe — ordering matters

The three-client livelock above is the loud version. There is a quieter one that
bites at **two** clients, and it is the same empty channel table by a different
route.

The bridge broadcasts the node's stream to *every* attached TCP client. So if
`mesh-api` attaches while `mqtt-proxy`'s dump is still in flight, the proxy can
see the shim's `configComplete`, conclude its own dump is finished, and carry on
with a channel table that is missing everything that went past during the
restart. It then drops every outbound packet "to prevent loops" — the correct
default for a genuinely unknown channel, and fatal when the channel is unknown
only because the config never arrived.

That ran for **79 hours** here before anyone noticed. Five services up, BLE
connected, radio packets arriving every few seconds, broker connected,
`MQTT Connected: True` in every status block, and `scripts/verify.sh` passing
throughout.

Two log lines actively mislead while it is happening:

- `uplink_enabled=False for channel 'LongFast'` reads as *the node has uplink
  disabled*. It does not. It means "no channel by that name, so I assumed
  false". Check the node itself — `meshtastic --info` will show
  `uplink_enabled: True`. Do not go changing the channel to match: `mqtt-proxy`
  already resolves an unnamed primary channel to `LongFast`, so a blank name is
  not your problem.
- `MQTT Activity: Ns ago` counts **inbound** broker traffic. It keeps ticking
  over happily while nothing whatsoever is being published.
- `Node->MQTT: Topic=` is logged for **every** packet considered, including
  ones then dropped. It counts attempts, not successes. Real uplinks are
  attempts minus drops.

And not every drop is a fault: Meshtastic sends key-exchange traffic on a `PKI`
channel that is not configured on the node, and dropping an unknown channel is
correct loop prevention. The failure signature is **everything** dropped, not
some.

## The third way it dies: the bridge gives up and stays running

Power-cycle the node for a couple of minutes and the bridge retries **10 times
at 60s intervals**, logs `Failed to reconnect to BLE device after all attempts`,
exits its polling loop — and keeps running. Container up, unit `active`, TCP
still accepting clients, BLE gone permanently. `Restart=always` cannot help,
because the process never exits. That cost three hours here before anyone
looked.

The first version of the watchdog keyed only on `Dropping Node->MQTT` and was
structurally blind to it: an unconnected proxy drops nothing, so it reported
`ok ... (uplinked=0)` repeatedly while the gateway was dead. **Absence of
badness is not liveness.**

### Fixing it properly

It gives up in **two independent places**, and only one is a constant:

```
core/ble_handler.py  MAX_RECONNECT_ATTEMPTS = 10   class constant
    -> "Maximum reconnection attempts (10) exceeded. Giving up."
core/ble_handler.py  max_wait = 600                local, inside the poll loop
    -> "Reconnection failed after waiting, exiting polling loop"
```

So patching constants cannot fix this — the second is a local variable in a
method, and monkeypatching the whole polling loop would weld you to upstream's
implementation. The bridge's own log output is the only stable interface to
both, and that is what `host/ble-bridge-entrypoint.sh` watches. It runs the
bridge, passes every line through unchanged so `docker logs` / `podman logs`
are unaffected, and the moment the bridge announces it has given up it kills
the child's process group and exits non-zero. Your runtime then **recreates**
the container — which is the recovery that actually works, because a plain
restart reuses dead BLE session state.

It is wired as the entrypoint in both `quadlet/ble-bridge.container` and
`docker-compose.yml`. A brief node outage now self-heals with no watchdog and
no human.

## What guards all of this

| Guard | What it does |
|---|---|
| `host/ble-bridge-entrypoint.sh` | Exits the container when the bridge gives up, so your runtime recreates it. The fix for that failure, not a backstop. |
| `host/wait-for-mqtt-proxy-config.sh` | `ExecStartPre` on `mesh-api`. `After=` alone is not enough — a quadlet unit is active the moment its container launches, while the proxy still needs ~40s. This is what keeps the shim off the bridge during the dump. Never fails closed: a dead proxy must not also cost you the UI. |
| `host/mesh-uplink-watchdog.{sh,service,timer}` | Checks every 10 min on four signals (below) and routes to the matching repair. Works under Compose too: `RESTART_MODE=compose CTR=docker COMPOSE_DIR=$PWD`. |
| `scripts/verify.sh` | Asserts no drops in the last 15 min, rather than only that the broker is reachable. |

| Signal | Meaning | Repair |
|---|---|---|
| `Failed to reconnect to BLE device after all attempts` newer than the last `Connected to BLE device` | bridge gave up, alive with no radio | recreate the container — a plain restart reuses dead BLE session state — then ordered restart |
| `Cannot send to BLE - not connected` | same, caught sooner | as above |
| **All** packets dropped (attempts > 0, none surviving) | empty channel table | ordered proxy restart |
| `Timed out waiting for connection completion` | proxy stuck in a connect loop | ordered proxy restart |
| `Radio Activity: Ns ago` beyond `RADIO_MAX` (default 1h) | nothing arriving at all | recreate the bridge |

The first four only appear when something *did* happen and went wrong, so a
quiet mesh cannot trigger them. The last is the positive-liveness check. Note
the drop row is *all* dropped, not any: a few dropped `PKI` packets are normal
and must not trigger a repair.

Set `HC_PING_URL` in `/etc/mesh-gateway/watchdog.env` (chmod 600, see
`config/watchdog.env.example`), or the watchdog repairs quietly and nothing
tells you it happened. It appends `/start` before a repair and `/fail` if the
repair does not take. Hosted and self-hosted healthchecks use different ping
paths; the example file shows both.

**Manual recovery**, if you need it: stop `mesh-api` *and* `mqtt-proxy`, start
`mqtt-proxy` alone, wait for `Node config fully loaded` followed by a
`Node->MQTT: Topic=` line with no drop after it, then start `mesh-api`. The
proxy must take its config dump with nothing else attached to 4403.

## Why the shim exists

A Meshtastic client attaches over one of four transports: Serial, BLE, TCP, or
the node's HTTP API. A node with WiFi serves the HTTP one itself. A node with no
network hardware serves none of it — leaving only the bridge's raw TCP, which is
exactly the transport a browser cannot use. JavaScript has no raw TCP socket API.

So `shim/http_api_shim.py` impersonates the HTTP API the node would have served
if it had WiFi. Two endpoints is the whole surface:

```
GET  /api/v1/fromradio   -> one queued FromRadio protobuf (empty if none)
PUT  /api/v1/toradio     -> frame and forward one ToRadio protobuf
```

It also handles the Meshtastic stream framing (`0x94 0xC3 <len_hi> <len_lo>`),
CORS (a TCP socket has no concept of an `Origin` header), and the per-client
queues described above. 215 lines, standard library only, so it runs in a bare
`python:alpine` container with no pip layer to maintain.

## What's upstream, what's here

| Component | Origin |
|---|---|
| `ble-bridge` | [Yeraze/meshtastic-ble-bridge](https://github.com/Yeraze/meshtastic-ble-bridge) |
| `mqtt-proxy` | [LN4CY/mqtt-proxy](https://github.com/LN4CY/mqtt-proxy) |
| `meshmonitor` | [Yeraze/MeshMonitor](https://github.com/Yeraze/meshmonitor) |
| `caddy` | [Caddy](https://caddyserver.com) |
| `shim/http_api_shim.py` | **this repo** — the HTTP API translator |
| `config/mqtt-proxy-patch/` | **this repo** — timeout patch, mounted into the stock image (no fork) |
| `quadlet/`, `scripts/` | **this repo** — podman/systemd units and deploy helpers |
| `host/ble-bridge-entrypoint.sh` | **this repo** — makes the bridge exit instead of living on with no radio |
| `host/mesh-uplink-watchdog.sh` | **this repo** — detects and repairs a silently dead uplink |

## Things that cost us a day each

- **Don't send serial config-writes while the bridge holds BLE.** A known
  firmware bug ([#8747](https://github.com/meshtastic/firmware/issues/8747)) can
  wedge Bluetooth until the node is physically rebooted. On a roof, that matters.
- **Don't poll — hold the connection.** The firmware's MQTT-proxy queue is 8 deep
  and drops oldest. A periodic poller silently sheds uplinks between connections.
- **Firmware 2.8.0 ignores config writes from 2.7-protobuf clients.** The client
  reports success while the node discards everything. Install `meshtastic` from
  git until a 2.8 release lands. A firmware major upgrade also regenerates the
  node id and wipes the BLE bond — expect to re-pair and to get a new gateway id.
- **A wedged bridge needs a container recreate, not a restart.** A restart reuses
  the dead BLE session state.
- **A dongle that scans nothing while another radio scans fine is wedged.**
  Re-enumerate it with the sysfs `authorized` toggle rather than rebooting.

## Deploying with podman + systemd instead

`quadlet/*.container` are the same five services as systemd units, and
`scripts/deploy.sh` pushes them to a host. That is how the original runs; the
Compose file is the portable equivalent. Note that quadlet regenerates units at
boot, so `systemctl disable` does not persist — use `systemctl mask`.

## Credits

Built on the work of [Yeraze](https://github.com/Yeraze) and
[LN4CY](https://github.com/LN4CY). Thank you.

Meshtastic® is a registered trademark of Meshtastic LLC. This is a community
project and is not affiliated with or endorsed by Meshtastic LLC.

## License

[GLWTPL](LICENSE) — the [Good Luck With That Public License](https://github.com/me-shaon/GLWTPL).
