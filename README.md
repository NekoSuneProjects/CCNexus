# CCNexus

**CCNexus** is an open-source, self-hosted browser control plane for **CC:Tweaked** computers and turtles across multiple Minecraft servers and single-player worlds.

## Highlights

- Multi-server / multi-world workspaces with offline cached telemetry.
- First-boot setup wizard with **SQLite, MySQL/MariaDB, PostgreSQL, or MongoDB** persistence.
- Username/password accounts with **Administrator** and **User** roles.
- Per-device short-lived pairing codes and revocable device credentials.
- Modern responsive dashboard for devices, worlds, turtles, storage, AE2, monitors and automation.
- YouTube, direct media and live-radio routing to CC:Tweaked speakers.
- Per-world media queue with play/pause/resume/skip/stop/clear and live volume.
- Local TTS through `espeak-ng` with no cloud speech account required.
- Admin fleet update workflow with spoken warning/grace period and fleet reboot.
- Installer v0.3 startup updater: rebooted nodes fetch the current self-hosted CCNexus agent before launch.
- Turtle quarry, crop farming and tree-service-lane automation.
- Generic inventory, Forge Energy and fluid peripheral telemetry.
- Applied Energistics 2 storage/search/autocrafting through an Advanced Peripherals ME Bridge.
- Advanced Monitor pages with touch navigation.
- Standalone Node.js or Docker deployment.
- GHCR image publishing remains **release-tag only**.

## Docker quick start

```bash
cp .env.example .env
# Set CCNEXUS_PUBLIC_URL when using a reverse proxy.
docker compose up -d --build
```

Open `http://localhost:3000`. On first boot the web UI asks which database backend to use and creates the first Administrator account.

Persist `./data`. Even with MySQL/PostgreSQL/MongoDB, this directory contains `config.json`, which tells CCNexus how to reconnect to the selected backend after a restart.

## Standalone quick start

Requirements:

- Node.js 22+
- npm
- FFmpeg for arbitrary media
- yt-dlp for YouTube
- espeak-ng for local TTS

```bash
npm install
export CCNEXUS_PUBLIC_URL="https://ccnexus.example.com"
npm start
```

Then complete first-boot setup in the browser.

## Pair a CC:Tweaked node

1. Sign in.
2. Select or create a **Server / World** workspace.
3. Press **Pair device** and create a 10-minute pairing code.
4. On the CC:Tweaked computer/turtle run:

```lua
wget run https://YOUR-CCNEXUS-DOMAIN/install.lua
```

5. Enter the dashboard URL and pairing code.

Installer v0.3 saves the per-device credential and writes `/startup/ccnexus.lua`. The startup hook checks the self-hosted dashboard for the latest agent before launching it, allowing Admin fleet maintenance to update nodes through a warned reboot.

> CC:Tweaked HTTP/WebSocket access must allow the CCNexus hostname. Private/local hosts may need ComputerCraft HTTP allow-list changes.

## Accounts

Normal **Users** get the Minecraft controls and integrations. **Administrators** additionally manage users, database/system information, scheduled fleet updates and immediate fleet reboots.

See [`docs/AUTH_DATABASE.md`](docs/AUTH_DATABASE.md).

## Audio Nexus

A Server/World has its own queue and speaker targets. Supported entries are:

- YouTube links;
- direct audio/video links;
- live radio/stream URLs;
- TTS messages.

CC:Tweaked speakers consume 48 kHz 8-bit PCM. CCNexus performs decoding/transcoding on the self-hosted server so CraftOS only handles speaker playback.

See [`docs/MEDIA.md`](docs/MEDIA.md).

## Storage / AE2

CCNexus capability-scans connected peripherals. Generic CC:Tweaked inventories and Forge Energy stores appear automatically. AE2 integration is provided by an **Advanced Peripherals ME Bridge**, including searchable ME item cache and dashboard `craftItem` requests.

See [`docs/INTEGRATIONS.md`](docs/INTEGRATIONS.md).

## Turtle automation

Current movement jobs include:

- quarry mining;
- mature vanilla crop harvesting/replanting;
- tree service-lane harvesting/replanting.

See [`docs/AUTOMATION.md`](docs/AUTOMATION.md).

## Update warnings

Administrators can choose a workspace or every workspace, select **Turtles only** or **All CC nodes**, and schedule an update warning (default five minutes). Speaker nodes receive a TTS notice immediately. At the deadline online selected nodes reboot; v0.3 startup hooks fetch the latest agent first.

Older 0.1/0.2 nodes should run the v0.3 installer once to receive the self-updating startup hook.

## Release-only Docker publishing

Normal pushes do **not** publish GHCR images. The existing GitHub Actions workflow only runs for tags matching:

```text
v*
ccnexus-v*
```

Example:

```bash
git tag ccnexus-v0.3.0
git push origin ccnexus-v0.3.0
```

The release workflow builds `linux/amd64` and `linux/arm64` images.

## Security

- Put internet-facing CCNexus deployments behind HTTPS/WSS.
- Keep `data/` private; remote database credentials may exist in `data/config.json`.
- Pairing codes are short-lived and single-use.
- Device tokens remain revocable.
- Passwords are bcrypt-hashed and sessions are server-side with HttpOnly cookies.
- Admin-only fleet operations are separate from normal User integrations.

## License

MIT
