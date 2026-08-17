# CCNexus

**CCNexus** is an open-source, self-hosted multi-world control plane for Minecraft computers running **CC:Tweaked**. One browser dashboard can manage independent dedicated servers and single-player worlds, while CraftOS agents report turtles, inventories, Forge Energy, tanks, monitors, speakers and supported mod peripherals back to the central Nexus.

## Highlights in 0.2

- **Multi-server / multi-world workspaces** — every pairing code belongs to one workspace, keeping devices and telemetry isolated by Minecraft instance.
- **Offline telemetry cache** — a stopped Minecraft server or closed single-player save remains visible with its last known items, FE, ME storage, turtle state and activity.
- **Storage & AE2 dashboard** — searchable item index across generic CC:Tweaked inventories and Advanced Peripherals ME Bridges.
- **AE2 autocrafting** — queue `craftItem` requests through an Advanced Peripherals ME Bridge.
- **Forge Energy telemetry** — discover compatible energy blocks and show stored/capacity FE.
- **Fluid discovery** — cache compatible fluid-storage peripherals for future logistics rules and dashboards.
- **In-world monitor dashboards** — deploy Overview, Storage, Energy, AE2 or Farm status pages to connected monitors.
- **Farming turtle** — mature vanilla crop harvesting + replanting in a serpentine grid.
- **Tree farming turtle** — service-lane tree harvesting/replanting for vanilla log trees.
- **Quarry turtle** — width × length × depth mining with live job state.
- **Audio Nexus** — route YouTube/direct media through FFmpeg to CC:Tweaked speakers.
- **Redstone automation** — remote binary/analogue outputs for lights and machines.
- **Standalone or Docker** — no cloud database required.
- **Release-only Docker publishing** — GHCR images are built only when a matching version tag is pushed.

## How multi-world works

CCNexus itself is one central web service. Inside the dashboard you create workspaces such as:

- `Main Survival SMP`
- `Create Mod Server`
- `Skyblock Single Player`
- `Testing World`

Select a workspace before generating a pairing code. That code carries the workspace identity, so the CraftOS installer only needs your CCNexus URL + pairing code. The resulting device token stays assigned to that workspace.

When Minecraft is offline, **CCNexus cannot execute new in-game commands** because CraftOS is not running. The dashboard still retains the most recent telemetry so you can inspect that world without it being online.

## Quick start — Docker

```bash
cp .env.example .env
# Set CCNEXUS_PUBLIC_URL and CCNEXUS_ADMIN_TOKEN.
docker compose up -d --build
```

Open `http://localhost:3000` or your reverse-proxied hostname.

## Quick start — standalone

Requirements: Node.js 20+. FFmpeg and yt-dlp are optional unless you use remote media playback.

```bash
npm install
export CCNEXUS_PUBLIC_URL="https://ccnexus.example.com"
export CCNEXUS_ADMIN_TOKEN="use-a-long-random-secret"
npm start
```

State is stored in `./data/state.json` by default. Set `CCNEXUS_DATA_DIR` to change it.

## Pair a CC:Tweaked computer

1. Create/select a **Server / World** workspace.
2. Press **Pair device** and generate a 10-minute code.
3. On the CC:Tweaked computer or turtle run:

```lua
wget run https://YOUR-CCNEXUS-DOMAIN/install.lua
```

4. Enter the dashboard URL and pairing code.
5. The installer downloads `/ccnexus/agent.lua`, writes `/ccnexus/config.json`, and creates `/startup/ccnexus.lua`.

The installer does not replace an existing root `startup.lua`.

> CC:Tweaked HTTP/WebSocket rules must allow the CCNexus hostname. Private/local addresses may need explicit server configuration.

## Storage, FE and fluids

CCNexus capability-scans attached/wired peripherals rather than relying only on block names.

### Generic inventories

Compatible CC:Tweaked inventories are sampled and aggregated into a searchable dashboard index. The agent reports inventory size, used slots and item counts.

### Forge Energy

Blocks exposing CC:Tweaked's generic energy storage methods are reported with:

- current stored FE
- maximum FE capacity

Forge's generic energy API does not expose reliable per-tick throughput, so CCNexus does not invent an FE/t graph from those generic calls.

### Fluids

Blocks exposing CC:Tweaked fluid storage are discovered and their tank contents are cached. Transfer/routing automation is a planned module on top of the already collected data.

## Applied Energistics 2

For dashboard-level AE2 interaction, install **Advanced Peripherals** and attach an **ME Bridge** to the AE2 network.

CCNexus currently uses the bridge for:

- ME connection state
- item listing
- craftability where exposed by the installed AP version
- ME energy values where exposed
- `craftItem` requests
- multiple ME Bridge discovery per CraftOS node

The dashboard's **Storage & AE2** page lets you search cached ME items and queue an autocraft by registry name/count.

Advanced Peripherals changed some bridge names/APIs between Minecraft versions. CCNexus therefore detects both known ME Bridge type names and compatible method sets.

## Farming automation

### Crop grid

Place a turtle above/at the start of a rectangular farm so crops are directly below its route. Configure:

- width
- length
- seed/replant item slot
- number of cycles
- optional delay between cycles

The first implementation understands maturity states for vanilla wheat, carrots, potatoes, beetroot and nether wart. Test a small field before running large farms.

### Tree service lane

The tree worker assumes:

- the turtle starts on a clear walking lane
- it faces along the lane
- tree trunks/saplings are on the turtle's **right-hand side**
- configured spacing is the distance between tree stations
- the configured turtle slot contains the replacement sapling

It harvests supported vanilla logs vertically, returns to the service lane, replants, advances to the next tree, and returns along the lane after completing the row.

## Monitors

A computer with attached CC:Tweaked monitors can be assigned one of these in-world pages from the browser:

- Nexus Overview
- Inventory Storage
- Forge Energy
- AE2 / ME Storage
- Automation Job

Advanced monitors use colour automatically. Monitor rendering happens in CraftOS, not in the browser.

## Turtle GPS / quarry

Absolute positions use `gps.locate()`, so a CC:Tweaked GPS constellation is required for the map. Mining still works without GPS, but the dashboard cannot place that turtle at an absolute X/Z location.

Keep fuel available and test conservative quarry dimensions first. Protected blocks, unloaded chunks, other mods and entities can interrupt movement.

## Audio pipeline

Direct media:

`URL → FFmpeg → 48 kHz mono signed 8-bit PCM → WebSocket → CC:Tweaked speaker`

YouTube:

`YouTube URL → yt-dlp → FFmpeg → PCM → speaker`

The Docker image includes FFmpeg and yt-dlp. Standalone installs must provide them in `PATH` or set `FFMPEG_BIN` / `YTDLP_BIN`.

Use media you are permitted to access and follow the source platform's terms.

## Architecture

```text
Browser Dashboard
      │
      │ HTTPS / REST
      ▼
  CCNexus Node.js
      │
      ├── persistent state.json
      ├── cached world telemetry
      ├── yt-dlp / FFmpeg audio
      │
      └── WSS device sessions
              │
              ├── World A computer/turtles
              ├── World B computer/turtles
              └── Single-player save computers
```

See [`docs/INTEGRATIONS.md`](docs/INTEGRATIONS.md) for the capability model and planned adapters.

## Release-only Docker publishing

Normal pushes **do not publish a container**. `.github/workflows/release.yml` only runs for tags matching:

```text
v*
ccnexus-v*
```

Example:

```bash
git tag ccnexus-v0.2.0
git push origin ccnexus-v0.2.0
```

The release workflow builds `linux/amd64` and `linux/arm64` images for GHCR.

## Security

- Set a strong `CCNEXUS_ADMIN_TOKEN` before exposing the dashboard publicly.
- Use HTTPS/WSS on public deployments.
- Pairing codes are short-lived and single-use.
- Every CC computer receives a unique revocable device token.
- Treat `data/` as sensitive because it contains device credentials and cached world telemetry.
- Do not expose arbitrary peripheral method execution to untrusted dashboard users.

## Good next integrations

The capability layer is intentionally ready for additional modules. Strong candidates include:

- Advanced Peripherals **RS Bridge / Refined Storage**
- Create machine/train/station telemetry
- Mekanism machine/tank/chemical dashboards where peripherals expose them
- reactor/turbine monitoring
- inventory routing rules (`keep 512 cobblestone`, `export excess iron`)
- automatic farm schedules
- turtle home/dock/refuel/unload stations
- alarms and Discord/webhook notifications
- monitor touch menus
- printer reports
- rednet-local fallback networks
- fluid routing controls
- historical charts stored separately from the live state cache

Feature requests are welcome through the repository's **Feature Request** issue form.

## License

MIT
