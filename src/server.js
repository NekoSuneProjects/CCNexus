import express from 'express';
import http from 'node:http';
import path from 'node:path';
import fs from 'node:fs';
import crypto from 'node:crypto';
import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { WebSocketServer, WebSocket } from 'ws';
import { Store } from './store.js';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(__dirname, '..');
const port = Number(process.env.PORT || 3000);
const dataDir = process.env.CCNEXUS_DATA_DIR || path.join(root, 'data');
const store = new Store(path.join(dataDir, 'state.json'));
const app = express();
const server = http.createServer(app);
const wss = new WebSocketServer({ noServer: true, maxPayload: 1024 * 1024 });
const sockets = new Map();
const audioJobs = new Map();

app.use(express.json({ limit: '2mb' }));
app.use(express.static(path.join(root, 'public')));

function auth(req, res, next) {
  const token = req.headers.authorization?.replace(/^Bearer\s+/i, '');
  const expected = store.token();
  if (!token || token.length !== expected.length || !crypto.timingSafeEqual(Buffer.from(token), Buffer.from(expected))) {
    return res.status(401).json({ error: 'Invalid admin token' });
  }
  next();
}

function send(deviceId, payload) {
  const ws = sockets.get(deviceId);
  if (!ws || ws.readyState !== WebSocket.OPEN) return false;
  ws.send(JSON.stringify(payload));
  return true;
}

function publicUrl(req) {
  return process.env.CCNEXUS_PUBLIC_URL || `${req.protocol}://${req.get('host')}`;
}

function worldFor(id) { return store.state.worlds[id]; }
function requireWorld(id, res) {
  const world = worldFor(id);
  if (!world) res.status(404).json({ error: 'World/workspace not found' });
  return world;
}

app.get('/api/meta', (req, res) => res.json({ name: 'CCNexus', version: '0.2.0', authRequired: true, publicUrl: publicUrl(req) }));
app.post('/api/login', (req, res) => res.json({ ok: req.body?.token === store.token() }));
app.get('/api/state', auth, (req, res) => res.json({
  worlds: store.safeWorlds(),
  defaultWorldId: store.state.defaultWorldId,
  devices: store.safeDevices(),
  activity: store.state.activity,
  publicUrl: publicUrl(req)
}));

app.post('/api/worlds', auth, (req, res) => {
  const name = String(req.body?.name || '').trim();
  if (!name) return res.status(400).json({ error: 'World/server name is required' });
  res.status(201).json(store.createWorld(req.body));
});

app.delete('/api/worlds/:id', auth, (req, res) => {
  const result = store.removeWorld(req.params.id);
  if (result.ok) return res.json(result);
  if (result.reason === 'not-found') return res.status(404).json({ error: 'World/workspace not found' });
  if (result.reason === 'has-devices') return res.status(409).json({ error: `Remove its ${result.linked} linked device(s) first` });
  return res.status(409).json({ error: 'CCNexus must keep at least one world/workspace' });
});

app.post('/api/pairing-code', auth, (req, res) => {
  const worldId = req.body?.worldId || store.state.defaultWorldId;
  if (!requireWorld(worldId, res)) return;
  res.json({ code: store.createPairCode(worldId), expiresIn: 600, worldId });
});

app.post('/api/pair', (req, res) => {
  const { code, computerId, label, kind } = req.body || {};
  const worldId = store.consumePairCode(code);
  if (!worldId) return res.status(403).json({ error: 'Pairing code invalid or expired' });
  if (computerId === undefined || computerId === null) return res.status(400).json({ error: 'computerId is required' });
  const device = store.pairDevice({ computerId, label, kind, worldId });
  const world = worldFor(worldId);
  res.json({ deviceId: device.id, deviceToken: device.token, worldId, worldName: world?.name || 'Minecraft World' });
});

app.delete('/api/devices/:id', auth, (req, res) => {
  const device = store.state.devices[req.params.id];
  if (!device) return res.status(404).json({ error: 'Device not found' });
  sockets.get(device.id)?.close(4001, 'Device removed');
  delete store.state.devices[device.id]; store.save();
  store.addActivity('device', `Removed ${device.label}`, { worldId: device.worldId });
  res.json({ ok: true });
});

app.post('/api/devices/:id/command', auth, (req, res) => {
  const device = store.state.devices[req.params.id];
  if (!device) return res.status(404).json({ error: 'Device not found' });
  const command = req.body || {};
  const ok = send(req.params.id, { type: 'command', id: crypto.randomUUID(), command });
  if (!ok) return res.status(409).json({ error: 'Device is offline; cached data is still available' });
  store.addActivity('command', `${command.type || 'command'} sent to ${device.label}`, { command, worldId: device.worldId, deviceId: device.id });
  res.json({ ok: true });
});

app.post('/api/lights/:id', auth, (req, res) => {
  const { side = 'back', on = true, strength = null } = req.body || {};
  const command = strength === null ? { type: 'redstone', side, on: Boolean(on) } : { type: 'redstone_analog', side, strength: Number(strength) };
  if (!send(req.params.id, { type: 'command', id: crypto.randomUUID(), command })) return res.status(409).json({ error: 'Device is offline' });
  res.json({ ok: true });
});

app.post('/api/automation/:id', auth, (req, res) => {
  const allowed = new Set(['farm_start', 'tree_farm_start', 'job_pause', 'job_resume', 'job_stop']);
  const command = req.body || {};
  if (!allowed.has(command.type)) return res.status(400).json({ error: 'Unsupported automation command' });
  if (!send(req.params.id, { type: 'command', id: crypto.randomUUID(), command })) return res.status(409).json({ error: 'Device is offline' });
  res.json({ ok: true });
});

app.post('/api/monitors/:id', auth, (req, res) => {
  const page = String(req.body?.page || 'overview');
  if (!['overview', 'storage', 'energy', 'ae2', 'farm'].includes(page)) return res.status(400).json({ error: 'Unknown monitor page' });
  if (!send(req.params.id, { type: 'command', id: crypto.randomUUID(), command: { type: 'monitor_set', page } })) return res.status(409).json({ error: 'Device is offline' });
  res.json({ ok: true });
});

app.post('/api/ae2/:id/craft', auth, (req, res) => {
  const item = String(req.body?.item || '').trim();
  const count = Math.max(1, Math.min(1000000, Number(req.body?.count) || 1));
  const bridge = String(req.body?.bridge || '').trim();
  if (!item) return res.status(400).json({ error: 'Item registry name is required' });
  const command = { type: 'ae2_craft', item, count, bridge: bridge || undefined };
  if (!send(req.params.id, { type: 'command', id: crypto.randomUUID(), command })) return res.status(409).json({ error: 'ME Bridge computer is offline' });
  store.addActivity('ae2', `Requested ${count} × ${item}`, { deviceId: req.params.id, item, count });
  res.json({ ok: true });
});

app.get('/api/storage', auth, (req, res) => {
  const worldId = String(req.query.worldId || store.state.defaultWorldId);
  if (!requireWorld(worldId, res)) return;
  const query = String(req.query.q || '').toLowerCase().trim();
  const items = new Map();
  let fe = 0, feCapacity = 0, aeStored = 0, aeCapacity = 0;
  for (const d of Object.values(store.state.devices)) {
    if (d.worldId !== worldId) continue;
    for (const item of d.telemetry?.storage?.items || []) {
      const key = item.name || item.displayName;
      if (!key) continue;
      const prev = items.get(key) || { name: key, displayName: item.displayName || key, count: 0, sources: 0, kind: 'inventory' };
      prev.count += Number(item.count || item.amount || 0); prev.sources++; items.set(key, prev);
    }
    for (const item of d.telemetry?.ae2?.items || []) {
      const key = item.name || item.displayName;
      if (!key) continue;
      const prev = items.get(key) || { name: key, displayName: item.displayName || key, count: 0, sources: 0, kind: 'ae2', craftable: false };
      prev.count += Number(item.amount || item.count || 0); prev.sources++; prev.kind = 'ae2'; prev.craftable ||= Boolean(item.isCraftable || item.craftable); items.set(key, prev);
    }
    for (const e of d.telemetry?.energy || []) { fe += Number(e.energy || 0); feCapacity += Number(e.capacity || 0); }
    aeStored += Number(d.telemetry?.ae2?.energy?.stored || 0);
    aeCapacity += Number(d.telemetry?.ae2?.energy?.capacity || 0);
  }
  let out = [...items.values()].sort((a, b) => b.count - a.count || a.displayName.localeCompare(b.displayName));
  if (query) out = out.filter(i => `${i.name} ${i.displayName}`.toLowerCase().includes(query));
  res.json({ worldId, items: out.slice(0, 2000), totalTypes: out.length, energy: { fe, capacity: feCapacity, aeStored, aeCapacity } });
});

function stopAudio(id) {
  const job = audioJobs.get(id);
  if (!job) { send(id, { type: 'audio_stop' }); return; }
  if (!job.killed) {
    job.killed = true;
    job.ffmpeg?.kill('SIGKILL');
    job.ytdlp?.kill('SIGKILL');
  }
  for (const target of job.targets || [id]) {
    if (audioJobs.get(target) === job) audioJobs.delete(target);
    send(target, { type: 'audio_stop' });
  }
}

app.post('/api/audio/stop', auth, (req, res) => { const ids = req.body?.deviceIds || []; ids.forEach(stopAudio); res.json({ ok: true }); });

app.post('/api/audio/play', auth, async (req, res) => {
  const { url, deviceIds, volume = 1 } = req.body || {};
  if (!url || !Array.isArray(deviceIds) || !deviceIds.length) return res.status(400).json({ error: 'url and deviceIds are required' });
  const online = deviceIds.filter(id => sockets.get(id)?.readyState === WebSocket.OPEN);
  if (!online.length) return res.status(409).json({ error: 'No selected speaker device is online' });
  online.forEach(stopAudio);

  const job = { id: crypto.randomUUID(), killed: false, targets: online, volume: Math.max(0, Math.min(3, Number(volume) || 1)) };
  online.forEach(id => audioJobs.set(id, job));
  res.json({ ok: true, jobId: job.id, targets: online.length });

  let input = url;
  if (/^(https?:\/\/)?(www\.)?(youtube\.com|youtu\.be)\//i.test(url)) {
    const yt = spawn(process.env.YTDLP_BIN || 'yt-dlp', ['-f', 'bestaudio', '--no-playlist', '-g', url], { stdio: ['ignore', 'pipe', 'pipe'] });
    job.ytdlp = yt;
    let out = '', err = '';
    yt.stdout.on('data', d => out += d); yt.stderr.on('data', d => err += d); yt.on('error', e => err += e.message);
    const code = await new Promise(r => yt.on('close', r));
    if (code !== 0 || !out.trim()) {
      online.forEach(id => send(id, { type: 'audio_error', message: `yt-dlp failed: ${err.slice(-240)}` }));
      online.forEach(id => audioJobs.delete(id)); return;
    }
    input = out.trim().split(/\r?\n/)[0];
  }

  const ff = spawn(process.env.FFMPEG_BIN || 'ffmpeg', ['-hide_banner', '-loglevel', 'error', '-re', '-i', input, '-vn', '-ac', '1', '-ar', '48000', '-f', 's8', 'pipe:1'], { stdio: ['ignore', 'pipe', 'pipe'] });
  job.ffmpeg = ff;
  let error = '';
  ff.stderr.on('data', d => error += d); ff.on('error', e => { error += e.message; });
  ff.stdout.on('data', chunk => {
    if (job.killed) return;
    for (let offset = 0; offset < chunk.length; offset += 16384) {
      const part = chunk.subarray(offset, Math.min(chunk.length, offset + 16384));
      for (const id of online) {
        const ws = sockets.get(id);
        if (ws?.readyState === WebSocket.OPEN) ws.send(JSON.stringify({ type: 'audio_chunk', volume: job.volume, data: part.toString('base64') }));
      }
    }
  });
  ff.on('close', code => online.forEach(id => { if (audioJobs.get(id) === job) audioJobs.delete(id); send(id, { type: 'audio_end', ok: code === 0, error: error.slice(-240) }); }));
});

app.get('/install.lua', (req, res) => { res.type('text/plain').send(fs.readFileSync(path.join(root, 'lua', 'install.lua'), 'utf8')); });
app.get('/ccnexus.lua', (req, res) => { res.type('text/plain').send(fs.readFileSync(path.join(root, 'lua', 'ccnexus.lua'), 'utf8')); });
app.use((req, res) => res.sendFile(path.join(root, 'public', 'index.html')));

server.on('upgrade', (req, socket, head) => {
  const u = new URL(req.url, 'http://localhost');
  if (u.pathname !== '/ws/device') return socket.destroy();
  const device = store.byToken(u.searchParams.get('token'));
  if (!device) return socket.destroy();
  wss.handleUpgrade(req, socket, head, ws => wss.emit('connection', ws, req, device));
});

wss.on('connection', (ws, req, device) => {
  const previous = sockets.get(device.id);
  if (previous && previous !== ws) previous.close(4002, 'Replaced by a newer session');
  sockets.set(device.id, ws);
  device.online = true; device.lastSeen = Date.now(); store.save();
  const world = worldFor(device.worldId);
  store.addActivity('device', `${device.label} connected`, { deviceId: device.id, worldId: device.worldId });
  ws.send(JSON.stringify({ type: 'hello', deviceId: device.id, serverTime: Date.now(), world: world ? { id: world.id, name: world.name, type: world.type } : null }));

  ws.on('message', raw => {
    let msg; try { msg = JSON.parse(raw.toString()); } catch { return; }
    device.lastSeen = Date.now();
    if (msg.type === 'telemetry') {
      device.label = msg.label || device.label;
      device.kind = msg.kind || device.kind;
      device.peripherals = msg.peripherals || [];
      device.telemetry = msg.telemetry || {};
      store.save();
    } else if (msg.type === 'event') {
      store.addActivity('device-event', msg.message || 'Device event', { deviceId: device.id, worldId: device.worldId, ...msg });
    }
  });

  ws.on('close', () => {
    if (sockets.get(device.id) === ws) sockets.delete(device.id);
    device.online = false; device.lastSeen = Date.now(); store.save();
  });
});

server.listen(port, '0.0.0.0', () => {
  console.log(`\nCCNexus 0.2.0 listening on http://0.0.0.0:${port}`);
  if (!process.env.CCNEXUS_ADMIN_TOKEN) console.log(`Admin token: ${store.token()}\nSet CCNEXUS_ADMIN_TOKEN to override this persisted token.\n`);
});
