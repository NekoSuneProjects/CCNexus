import dotenv from 'dotenv';
import express from 'express';
import http from 'node:http';
import path from 'node:path';
import fs from 'node:fs';
import crypto from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { WebSocketServer, WebSocket } from 'ws';
import { Store } from './store.js';
import { MediaManager } from './media.js';
import { loadInstallConfig, saveInstallConfig, openDatabase, testDatabase, safeDatabaseInfo } from './database.js';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(__dirname, '..');
dotenv.config({ path: path.join(root, '.env') });
const port = Number(process.env.PORT || 3000);
const dataDir = process.env.CCNEXUS_DATA_DIR || path.join(root, 'data');
fs.mkdirSync(dataDir, { recursive: true });

const app = express();
app.set('trust proxy', 1);
const server = http.createServer(app);
const wss = new WebSocketServer({ noServer: true, maxPayload: 1024 * 1024 });
const sockets = new Map();
let installConfig = loadInstallConfig(dataDir);
let persistence = null;
let store = null;
let media = null;
let bootError = null;
let updateTimer = null;
const loginFailures = new Map();

app.use(express.json({ limit: '2mb' }));
app.use(express.static(path.join(root, 'public')));

function publicUrl(req) { return process.env.CCNEXUS_PUBLIC_URL || installConfig?.publicUrl || `${req.protocol}://${req.get('host')}`; }
function cookieMap(req) {
  const out = {};
  for (const part of String(req.headers.cookie || '').split(';')) {
    const i = part.indexOf('='); if (i < 0) continue;
    out[part.slice(0, i).trim()] = decodeURIComponent(part.slice(i + 1).trim());
  }
  return out;
}
function sessionToken(req) { return cookieMap(req).ccnexus_session || req.headers.authorization?.replace(/^Bearer\s+/i, '') || ''; }
function setSessionCookie(req, res, token) {
  const secure = req.secure || String(req.headers['x-forwarded-proto'] || '').split(',')[0].trim() === 'https';
  const attrs = [`ccnexus_session=${encodeURIComponent(token)}`, 'Path=/', 'HttpOnly', 'SameSite=Lax', 'Max-Age=604800'];
  if (secure) attrs.push('Secure');
  res.setHeader('Set-Cookie', attrs.join('; '));
}
function clearSessionCookie(res) { res.setHeader('Set-Cookie', 'ccnexus_session=; Path=/; HttpOnly; SameSite=Lax; Max-Age=0'); }
function requireReady(req, res, next) { if (!store) return res.status(503).json({ error: bootError ? 'Configured database is unavailable' : 'CCNexus first-boot setup is required', setupRequired: !installConfig }); next(); }
function requireUser(req, res, next) {
  if (!store) return res.status(503).json({ error: 'CCNexus setup is not complete' });
  const user = store.sessionUser(sessionToken(req)); if (!user) return res.status(401).json({ error: 'Authentication required' });
  req.user = user; next();
}
function requireAdmin(req, res, next) { requireUser(req, res, () => req.user.role === 'admin' ? next() : res.status(403).json({ error: 'Administrator permission required' })); }
function worldFor(id) { return store?.state.worlds[id]; }
function requireWorld(id, res) { const world = worldFor(id); if (!world) res.status(404).json({ error: 'World/workspace not found' }); return world; }
function send(deviceId, payload) { const ws = sockets.get(deviceId); if (!ws || ws.readyState !== WebSocket.OPEN) return false; ws.send(JSON.stringify(payload)); return true; }
function socketFor(id) { return sockets.get(id); }
function hasSpeaker(device) { return (device.peripherals || []).some(p => p.speaker || p.type === 'speaker'); }
function onlineSpeakerIds(worldId) { return Object.values(store.state.devices).filter(d => d.worldId === worldId && d.online && hasSpeaker(d)).map(d => d.id); }

async function bootstrap() {
  if (!installConfig?.database) return;
  try {
    persistence = await openDatabase(installConfig.database, dataDir);
    store = await Store.open(persistence);
    media = new MediaManager({ store, send, socketFor });
    bootError = null;
    restoreUpdateSchedule();
  } catch (err) {
    bootError = String(err?.message || err);
    console.error('[CCNexus] database boot failed:', err);
  }
}
await bootstrap();

app.get('/api/meta', (req, res) => {
  const user = store?.sessionUser(sessionToken(req)) || null;
  res.json({ name: 'CCNexus', version: '0.3.0', setupRequired: !installConfig, ready: Boolean(store), bootError: bootError ? 'Database connection failed. Check the CCNexus server logs.' : null, user, publicUrl: publicUrl(req) });
});
app.get('/api/setup/status', (req, res) => res.json({ setupRequired: !installConfig, ready: Boolean(store), bootError: bootError ? 'Database connection failed. Check the CCNexus server logs.' : null, database: installConfig?.database ? safeDatabaseInfo(installConfig.database) : null }));
app.post('/api/setup/test', async (req, res) => {
  if (store) return res.status(409).json({ error: 'Setup has already been completed' });
  try { const info = await testDatabase(req.body?.database || {}, dataDir); res.json({ ok: true, database: info }); }
  catch (err) { res.status(400).json({ error: String(err?.message || err) }); }
});
app.post('/api/setup/complete', async (req, res) => {
  if (store || installConfig) return res.status(409).json({ error: 'Setup has already been completed' });
  const database = req.body?.database || {};
  let candidate;
  try {
    candidate = await openDatabase(database, dataDir);
    let legacy = null;
    const legacyPath = path.join(dataDir, 'state.json');
    try { legacy = JSON.parse(fs.readFileSync(legacyPath, 'utf8')); } catch {}
    const nextStore = await Store.open(candidate, legacy);
    if (nextStore.userCount()) throw new Error('The selected database already contains CCNexus user accounts');
    const admin = await nextStore.createUser({ username: req.body?.username, password: req.body?.password, role: 'admin' });
    await nextStore.flush();
    installConfig = { version: 1, database, createdAt: Date.now() };
    saveInstallConfig(dataDir, installConfig);
    persistence = candidate; store = nextStore; media = new MediaManager({ store, send, socketFor }); bootError = null;
    const token = store.createSession(admin.id); await store.flush(); setSessionCookie(req, res, token);
    store.addActivity('system', 'CCNexus first-boot setup completed', { userId: admin.id, database: safeDatabaseInfo(database) });
    res.status(201).json({ ok: true, user: admin, importedLegacyState: Boolean(legacy), database: safeDatabaseInfo(database) });
  } catch (err) {
    try { await candidate?.close(); } catch {}
    res.status(400).json({ error: String(err?.message || err) });
  }
});

app.post('/api/login', requireReady, async (req, res) => {
  const key = req.ip || req.socket.remoteAddress || 'unknown'; const entry = loginFailures.get(key) || { count: 0, until: 0 };
  if (entry.until > Date.now()) return res.status(429).json({ error: 'Too many failed logins. Try again shortly.' });
  const user = await store.authenticate(req.body?.username, req.body?.password);
  if (!user) {
    entry.count++; if (entry.count >= 8) { entry.until = Date.now() + 60_000; entry.count = 0; } loginFailures.set(key, entry);
    return res.status(401).json({ error: 'Invalid username or password' });
  }
  loginFailures.delete(key); const token = store.createSession(user.id); setSessionCookie(req, res, token); store.addActivity('account', `${user.username} signed in`, { userId: user.id }); res.json({ ok: true, user });
});
app.post('/api/logout', requireReady, (req, res) => { store.destroySession(sessionToken(req)); clearSessionCookie(res); res.json({ ok: true }); });
app.get('/api/session', requireUser, (req, res) => res.json({ user: req.user }));

app.get('/api/state', requireUser, (req, res) => res.json({ worlds: store.safeWorlds(), defaultWorldId: store.state.defaultWorldId, devices: store.safeDevices(), activity: store.state.activity, publicUrl: publicUrl(req), user: req.user }));
app.post('/api/worlds', requireUser, (req, res) => { const name = String(req.body?.name || '').trim(); if (!name) return res.status(400).json({ error: 'World/server name is required' }); res.status(201).json(store.createWorld(req.body)); });
app.delete('/api/worlds/:id', requireUser, (req, res) => { const result = store.removeWorld(req.params.id); if (result.ok) return res.json(result); if (result.reason === 'not-found') return res.status(404).json({ error: 'World/workspace not found' }); if (result.reason === 'has-devices') return res.status(409).json({ error: `Remove its ${result.linked} linked device(s) first` }); res.status(409).json({ error: 'CCNexus must keep at least one world/workspace' }); });
app.post('/api/pairing-code', requireUser, (req, res) => { const worldId = req.body?.worldId || store.state.defaultWorldId; if (!requireWorld(worldId, res)) return; res.json({ code: store.createPairCode(worldId), expiresIn: 600, worldId }); });
app.post('/api/pair', requireReady, (req, res) => {
  const { code, computerId, label, kind } = req.body || {}; const worldId = store.consumePairCode(code);
  if (!worldId) return res.status(403).json({ error: 'Pairing code invalid or expired' });
  if (computerId === undefined || computerId === null) return res.status(400).json({ error: 'computerId is required' });
  const device = store.pairDevice({ computerId, label, kind, worldId }); const world = worldFor(worldId);
  res.json({ deviceId: device.id, deviceToken: device.token, worldId, worldName: world?.name || 'Minecraft World' });
});
app.delete('/api/devices/:id', requireUser, (req, res) => { const device = store.state.devices[req.params.id]; if (!device) return res.status(404).json({ error: 'Device not found' }); sockets.get(device.id)?.close(4001, 'Device removed'); delete store.state.devices[device.id]; store.save(); store.addActivity('device', `Removed ${device.label}`, { worldId: device.worldId, userId: req.user.id }); res.json({ ok: true }); });
app.post('/api/devices/:id/command', requireUser, (req, res) => { const device = store.state.devices[req.params.id]; if (!device) return res.status(404).json({ error: 'Device not found' }); const command = req.body || {}; if (!send(req.params.id, { type: 'command', id: crypto.randomUUID(), command })) return res.status(409).json({ error: 'Device is offline; cached data is still available' }); store.addActivity('command', `${command.type || 'command'} sent to ${device.label}`, { command, worldId: device.worldId, deviceId: device.id, userId: req.user.id }); res.json({ ok: true }); });
app.post('/api/lights/:id', requireUser, (req, res) => { const { side = 'back', on = true, strength = null } = req.body || {}; const command = strength === null ? { type: 'redstone', side, on: Boolean(on) } : { type: 'redstone_analog', side, strength: Number(strength) }; if (!send(req.params.id, { type: 'command', id: crypto.randomUUID(), command })) return res.status(409).json({ error: 'Device is offline' }); res.json({ ok: true }); });
app.post('/api/automation/:id', requireUser, (req, res) => { const allowed = new Set(['farm_start', 'tree_farm_start', 'job_pause', 'job_resume', 'job_stop']); const command = req.body || {}; if (!allowed.has(command.type)) return res.status(400).json({ error: 'Unsupported automation command' }); if (!send(req.params.id, { type: 'command', id: crypto.randomUUID(), command })) return res.status(409).json({ error: 'Device is offline' }); res.json({ ok: true }); });
app.post('/api/monitors/:id', requireUser, (req, res) => { const page = String(req.body?.page || 'overview'); if (!['overview', 'storage', 'energy', 'ae2', 'farm'].includes(page)) return res.status(400).json({ error: 'Unknown monitor page' }); if (!send(req.params.id, { type: 'command', id: crypto.randomUUID(), command: { type: 'monitor_set', page } })) return res.status(409).json({ error: 'Device is offline' }); res.json({ ok: true }); });
app.post('/api/ae2/:id/craft', requireUser, (req, res) => { const item = String(req.body?.item || '').trim(); const count = Math.max(1, Math.min(1000000, Number(req.body?.count) || 1)); const bridge = String(req.body?.bridge || '').trim(); if (!item) return res.status(400).json({ error: 'Item registry name is required' }); const command = { type: 'ae2_craft', item, count, bridge: bridge || undefined }; if (!send(req.params.id, { type: 'command', id: crypto.randomUUID(), command })) return res.status(409).json({ error: 'ME Bridge computer is offline' }); store.addActivity('ae2', `Requested ${count} × ${item}`, { deviceId: req.params.id, item, count, userId: req.user.id }); res.json({ ok: true }); });

app.get('/api/storage', requireUser, (req, res) => {
  const worldId = String(req.query.worldId || store.state.defaultWorldId); if (!requireWorld(worldId, res)) return; const query = String(req.query.q || '').toLowerCase().trim();
  const items = new Map(); let fe = 0, feCapacity = 0, aeStored = 0, aeCapacity = 0;
  for (const d of Object.values(store.state.devices)) {
    if (d.worldId !== worldId) continue;
    for (const item of d.telemetry?.storage?.items || []) { const key = item.name || item.displayName; if (!key) continue; const prev = items.get(key) || { name: key, displayName: item.displayName || key, count: 0, sources: 0, kind: 'inventory' }; prev.count += Number(item.count || item.amount || 0); prev.sources++; items.set(key, prev); }
    for (const item of d.telemetry?.ae2?.items || []) { const key = item.name || item.displayName; if (!key) continue; const prev = items.get(key) || { name: key, displayName: item.displayName || key, count: 0, sources: 0, kind: 'ae2', craftable: false }; prev.count += Number(item.amount || item.count || 0); prev.sources++; prev.kind = 'ae2'; prev.craftable ||= Boolean(item.isCraftable || item.craftable); items.set(key, prev); }
    for (const e of d.telemetry?.energy || []) { fe += Number(e.energy || 0); feCapacity += Number(e.capacity || 0); }
    aeStored += Number(d.telemetry?.ae2?.energy?.stored || 0); aeCapacity += Number(d.telemetry?.ae2?.energy?.capacity || 0);
  }
  let out = [...items.values()].sort((a, b) => b.count - a.count || a.displayName.localeCompare(b.displayName)); if (query) out = out.filter(i => `${i.name} ${i.displayName}`.toLowerCase().includes(query));
  res.json({ worldId, items: out.slice(0, 2000), totalTypes: out.length, energy: { fe, capacity: feCapacity, aeStored, aeCapacity } });
});

app.get('/api/media/:worldId', requireUser, (req, res) => { if (!requireWorld(req.params.worldId, res)) return; res.json(media.state(req.params.worldId)); });
app.post('/api/media/:worldId/queue', requireUser, async (req, res) => {
  const worldId = req.params.worldId; if (!requireWorld(worldId, res)) return;
  let ids = Array.isArray(req.body?.deviceIds) ? req.body.deviceIds.map(String) : []; if (!ids.length) ids = onlineSpeakerIds(worldId);
  const valid = ids.filter(id => store.state.devices[id]?.worldId === worldId && hasSpeaker(store.state.devices[id])); if (!valid.length) return res.status(409).json({ error: 'No speaker nodes selected in this workspace' });
  try { const item = await media.enqueue(worldId, req.body || {}, valid); res.status(201).json({ ok: true, item, media: media.state(worldId) }); } catch (err) { res.status(400).json({ error: String(err?.message || err) }); }
});
app.delete('/api/media/:worldId/queue/:itemId', requireUser, (req, res) => res.json(media.removeQueueItem(req.params.worldId, req.params.itemId)));
app.post('/api/media/:worldId/control', requireUser, async (req, res) => {
  const worldId = req.params.worldId; if (!requireWorld(worldId, res)) return; const action = String(req.body?.action || 'play');
  try {
    if (action === 'play') await media.play(worldId); else if (action === 'pause') media.pause(worldId); else if (action === 'resume') await media.resume(worldId); else if (action === 'skip') media.skip(worldId); else if (action === 'stop') media.stop(worldId, false); else if (action === 'clear') media.stop(worldId, true); else if (action === 'volume') media.setVolume(worldId, req.body?.volume); else return res.status(400).json({ error: 'Unknown media control' });
    res.json(media.state(worldId));
  } catch (err) { res.status(400).json({ error: String(err?.message || err) }); }
});
app.post('/api/media/:worldId/tts', requireUser, async (req, res) => {
  const worldId = req.params.worldId; if (!requireWorld(worldId, res)) return; let ids = Array.isArray(req.body?.deviceIds) ? req.body.deviceIds.map(String) : onlineSpeakerIds(worldId);
  try { const item = await media.enqueue(worldId, { type: 'tts', text: req.body?.text, title: req.body?.title || 'TTS announcement', voice: req.body?.voice, rate: req.body?.rate, volume: req.body?.volume, autoplay: req.body?.autoplay !== false }, ids); res.status(201).json({ ok: true, item, media: media.state(worldId) }); } catch (err) { res.status(400).json({ error: String(err?.message || err) }); }
});

// Backwards-compatible audio endpoints used by early 0.1/0.2 dashboard clients.
app.post('/api/audio/play', requireUser, async (req, res) => { const ids = req.body?.deviceIds || []; const first = store.state.devices[ids[0]]; if (!first) return res.status(400).json({ error: 'Select at least one speaker node' }); try { const item = await media.enqueue(first.worldId, { type: 'url', url: req.body?.url, volume: req.body?.volume, autoplay: true }, ids); res.json({ ok: true, jobId: item.id }); } catch (err) { res.status(400).json({ error: String(err?.message || err) }); } });
app.post('/api/audio/stop', requireUser, (req, res) => { const worlds = new Set((req.body?.deviceIds || []).map(id => store.state.devices[id]?.worldId).filter(Boolean)); for (const worldId of worlds) media.stop(worldId); res.json({ ok: true }); });

app.get('/api/admin/system', requireAdmin, async (req, res) => res.json({ database: persistence?.info?.() || safeDatabaseInfo(installConfig.database), version: '0.3.0', updateSchedule: store.state.system.updateSchedule, users: store.safeUsers(), onlineDevices: Object.values(store.state.devices).filter(d => d.online).length }));
app.get('/api/admin/users', requireAdmin, (req, res) => res.json({ users: store.safeUsers() }));
app.post('/api/admin/users', requireAdmin, async (req, res) => { try { const user = await store.createUser(req.body || {}); res.status(201).json({ user }); } catch (err) { res.status(400).json({ error: String(err?.message || err) }); } });
app.patch('/api/admin/users/:id', requireAdmin, async (req, res) => { try { const user = await store.updateUser(req.params.id, req.body || {}, req.user.id); res.json({ user }); } catch (err) { res.status(400).json({ error: String(err?.message || err) }); } });
app.delete('/api/admin/users/:id', requireAdmin, (req, res) => { try { store.deleteUser(req.params.id, req.user.id); res.json({ ok: true }); } catch (err) { res.status(400).json({ error: String(err?.message || err) }); } });

function selectFleet({ worldId = 'all', scope = 'turtles', onlineOnly = true } = {}) {
  return Object.values(store.state.devices).filter(d => (worldId === 'all' || d.worldId === worldId) && (scope === 'all' || d.kind === 'turtle') && (!onlineOnly || d.online));
}
function restoreUpdateSchedule() {
  const schedule = store?.state.system?.updateSchedule; if (!schedule) return;
  const delay = Number(schedule.executeAt || 0) - Date.now(); if (updateTimer) clearTimeout(updateTimer);
  if (delay <= 0) setTimeout(executeFleetUpdate, 200); else updateTimer = setTimeout(executeFleetUpdate, delay);
}
async function executeFleetUpdate() {
  if (!store) return; const schedule = store.state.system.updateSchedule; if (!schedule) return; updateTimer = null;
  const targets = selectFleet({ worldId: schedule.worldId, scope: schedule.scope, onlineOnly: true });
  for (const d of targets) send(d.id, { type: 'command', id: crypto.randomUUID(), command: { type: 'reboot', update: true, requestedAt: Date.now() } });
  store.addActivity('system', `Dispatched CCNexus agent update to ${targets.length} online ${schedule.scope === 'all' ? 'node(s)' : 'turtle(s)'}`, { worldId: schedule.worldId, targetCount: targets.length });
  store.state.system.updateSchedule = null; store.save();
}
app.post('/api/admin/fleet/reboot', requireAdmin, (req, res) => { const targets = selectFleet({ worldId: req.body?.worldId || 'all', scope: req.body?.scope || 'turtles', onlineOnly: true }); for (const d of targets) send(d.id, { type: 'command', id: crypto.randomUUID(), command: { type: 'reboot' } }); store.addActivity('system', `${req.user.username} rebooted ${targets.length} online node(s)`, { userId: req.user.id }); res.json({ ok: true, targets: targets.length }); });
app.post('/api/admin/fleet/update', requireAdmin, async (req, res) => {
  if (store.state.system.updateSchedule) return res.status(409).json({ error: 'A fleet update is already scheduled' });
  const minutes = Math.max(1, Math.min(60, Number(req.body?.minutes) || 5)); const worldId = req.body?.worldId || 'all'; const scope = req.body?.scope === 'all' ? 'all' : 'turtles';
  if (worldId !== 'all' && !requireWorld(worldId, res)) return;
  const targets = selectFleet({ worldId, scope, onlineOnly: true }); const executeAt = Date.now() + minutes * 60_000;
  const schedule = { id: crypto.randomUUID(), worldId, scope, minutes, createdAt: Date.now(), executeAt, createdBy: req.user.id }; store.state.system.updateSchedule = schedule; store.save();
  const warning = `CCNexus update scheduled in ${minutes} minute${minutes === 1 ? '' : 's'}. Please allow active turtle jobs to finish or pause them safely.`;
  for (const d of targets) send(d.id, { type: 'command', id: crypto.randomUUID(), command: { type: 'update_warning', minutes, message: warning, executeAt } });
  const affectedWorlds = new Set(targets.map(d => d.worldId));
  for (const wid of affectedWorlds) { const ids = onlineSpeakerIds(wid); if (ids.length) media.announce(wid, warning, ids, { volume: 1.15 }).catch(err => console.warn('[CCNexus] update TTS warning failed:', err.message)); }
  store.addActivity('system', `${req.user.username} scheduled a fleet update in ${minutes} minute(s)`, { userId: req.user.id, worldId, scope, executeAt, targets: targets.length }); restoreUpdateSchedule(); res.json({ ok: true, targets: targets.length, schedule });
});
app.post('/api/admin/fleet/update/cancel', requireAdmin, (req, res) => { if (updateTimer) clearTimeout(updateTimer); updateTimer = null; const old = store.state.system.updateSchedule; store.state.system.updateSchedule = null; store.save(); store.addActivity('system', `${req.user.username} cancelled the scheduled fleet update`, { userId: req.user.id, scheduleId: old?.id }); res.json({ ok: true }); });

app.get('/install.lua', (req, res) => { res.type('text/plain').send(fs.readFileSync(path.join(root, 'lua', 'install.lua'), 'utf8')); });
app.get('/ccnexus.lua', (req, res) => { res.type('text/plain').send(fs.readFileSync(path.join(root, 'lua', 'ccnexus.lua'), 'utf8')); });
app.use((req, res) => res.sendFile(path.join(root, 'public', 'index.html')));

server.on('upgrade', (req, socket, head) => {
  if (!store) return socket.destroy(); const u = new URL(req.url, 'http://localhost'); if (u.pathname !== '/ws/device') return socket.destroy(); const device = store.byToken(u.searchParams.get('token')); if (!device) return socket.destroy();
  wss.handleUpgrade(req, socket, head, ws => wss.emit('connection', ws, req, device));
});
wss.on('connection', (ws, req, device) => {
  const previous = sockets.get(device.id); if (previous && previous !== ws) previous.close(4002, 'Replaced by a newer session'); sockets.set(device.id, ws);
  device.online = true; device.lastSeen = Date.now(); store.save(); const world = worldFor(device.worldId); store.addActivity('device', `${device.label} connected`, { deviceId: device.id, worldId: device.worldId });
  ws.send(JSON.stringify({ type: 'hello', deviceId: device.id, serverTime: Date.now(), world: world ? { id: world.id, name: world.name, type: world.type } : null, agentVersion: '0.3.0' }));
  ws.on('message', raw => {
    let msg; try { msg = JSON.parse(raw.toString()); } catch { return; } device.lastSeen = Date.now();
    if (msg.type === 'telemetry') { device.label = msg.label || device.label; device.kind = msg.kind || device.kind; device.agentVersion = msg.agentVersion || device.agentVersion; device.peripherals = msg.peripherals || []; device.telemetry = msg.telemetry || {}; store.save(); }
    else if (msg.type === 'event') store.addActivity('device-event', msg.message || 'Device event', { deviceId: device.id, worldId: device.worldId, ...msg });
  });
  ws.on('close', () => { if (sockets.get(device.id) === ws) sockets.delete(device.id); device.online = false; device.lastSeen = Date.now(); store.save(); });
});

server.listen(port, '0.0.0.0', () => {
  console.log(`\nCCNexus 0.3 listening on http://0.0.0.0:${port}`);
  if (!installConfig) console.log('First boot: open the dashboard to choose a database and create the first admin account.');
  else if (bootError) console.log(`Database unavailable: ${bootError}`);
  else console.log(`Database: ${JSON.stringify(persistence?.info?.() || safeDatabaseInfo(installConfig.database))}`);
});

async function shutdown() { try { await store?.flush(); } catch {} try { await persistence?.close(); } catch {} process.exit(0); }
process.on('SIGTERM', shutdown); process.on('SIGINT', shutdown);
