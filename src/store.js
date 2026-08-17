import crypto from 'node:crypto';
import bcrypt from 'bcryptjs';

function now() { return Date.now(); }
function sessionHash(token) { return crypto.createHash('sha256').update(String(token)).digest('hex'); }
function cleanUsername(v) { return String(v || '').trim().toLowerCase(); }

export class Store {
  constructor(persistence, state) {
    this.persistence = persistence;
    this.state = state || this.fresh();
    this._saveChain = Promise.resolve();
    this.migrate();
  }

  static async open(persistence, seedState = null) {
    const loaded = await persistence.loadState();
    const store = new Store(persistence, loaded || seedState || null);
    await store.flush();
    return store;
  }

  fresh() {
    return {
      version: 3,
      worlds: {},
      defaultWorldId: null,
      devices: {},
      pairingCodes: {},
      scenes: [],
      activity: [],
      users: {},
      sessions: {},
      media: {},
      system: { updateSchedule: null }
    };
  }

  migrate() {
    this.state = { ...this.fresh(), ...(this.state || {}) };
    this.state.worlds ||= {};
    this.state.devices ||= {};
    this.state.pairingCodes ||= {};
    this.state.users ||= {};
    this.state.sessions ||= {};
    this.state.media ||= {};
    this.state.system ||= { updateSchedule: null };
    this.state.activity ||= [];
    if (!Object.keys(this.state.worlds).length) {
      this.state.worlds.default = { id: 'default', name: 'My Minecraft World', type: 'server', address: '', notes: '', createdAt: now(), updatedAt: now() };
      this.state.defaultWorldId = 'default';
    }
    if (!this.state.defaultWorldId || !this.state.worlds[this.state.defaultWorldId]) this.state.defaultWorldId = Object.keys(this.state.worlds)[0];
    for (const device of Object.values(this.state.devices)) {
      device.worldId ||= this.state.defaultWorldId;
      device.online = false;
      device.telemetry ||= {};
      device.peripherals ||= [];
    }
    this.pruneSessions(false);
    this.state.version = 3;
    this.save();
  }

  save() {
    const snapshot = structuredClone(this.state);
    this._saveChain = this._saveChain.then(() => this.persistence.saveState(snapshot)).catch(err => console.error('[CCNexus] persistence save failed:', err));
    return this._saveChain;
  }
  async flush() { await this._saveChain; }

  addActivity(type, message, meta = {}) {
    this.state.activity.unshift({ id: crypto.randomUUID(), type, message, meta, at: now() });
    this.state.activity = this.state.activity.slice(0, 500);
    this.save();
  }

  createWorld(input = {}) {
    const id = crypto.randomUUID();
    const world = { id, name: String(input.name || 'Minecraft World').trim().slice(0, 80), type: ['server', 'singleplayer', 'realm', 'other'].includes(input.type) ? input.type : 'server', address: String(input.address || '').trim().slice(0, 180), notes: String(input.notes || '').trim().slice(0, 500), createdAt: now(), updatedAt: now() };
    this.state.worlds[id] = world;
    if (!this.state.defaultWorldId) this.state.defaultWorldId = id;
    this.addActivity('world', `Created workspace ${world.name}`, { worldId: id });
    return world;
  }

  removeWorld(id) {
    const world = this.state.worlds[id];
    if (!world) return { ok: false, reason: 'not-found' };
    const linked = Object.values(this.state.devices).filter(d => d.worldId === id).length;
    if (linked) return { ok: false, reason: 'has-devices', linked };
    if (Object.keys(this.state.worlds).length <= 1) return { ok: false, reason: 'last-world' };
    delete this.state.worlds[id]; delete this.state.media[id];
    if (this.state.defaultWorldId === id) this.state.defaultWorldId = Object.keys(this.state.worlds)[0];
    this.addActivity('world', `Removed workspace ${world.name}`, { worldId: id });
    return { ok: true };
  }

  safeWorlds() {
    return Object.values(this.state.worlds).map(world => {
      const devices = Object.values(this.state.devices).filter(d => d.worldId === world.id);
      return { ...world, deviceCount: devices.length, onlineCount: devices.filter(d => d.online).length, lastSeen: devices.reduce((m, d) => Math.max(m, Number(d.lastSeen || 0)), 0) || null };
    });
  }

  createPairCode(worldId) {
    if (!this.state.worlds[worldId]) throw new Error('World/workspace not found');
    let code; do code = String(Math.floor(100000 + Math.random() * 900000)); while (this.state.pairingCodes[code]);
    this.state.pairingCodes[code] = { expiresAt: now() + 10 * 60 * 1000, worldId }; this.save(); return code;
  }

  consumePairCode(code) {
    const entry = this.state.pairingCodes[String(code)]; delete this.state.pairingCodes[String(code)]; this.save();
    if (!entry) return null;
    if (typeof entry === 'number') return entry > now() ? this.state.defaultWorldId : null;
    return entry.expiresAt > now() && this.state.worlds[entry.worldId] ? entry.worldId : null;
  }

  pairDevice(input) {
    const token = crypto.randomBytes(24).toString('hex'); const id = crypto.randomUUID();
    const device = { id, token, worldId: input.worldId || this.state.defaultWorldId, computerId: input.computerId, label: input.label || `Computer ${input.computerId}`, kind: input.kind || 'computer', online: false, peripherals: [], telemetry: {}, agentVersion: null, createdAt: now(), lastSeen: null };
    this.state.devices[id] = device;
    const world = this.state.worlds[device.worldId]; this.addActivity('device', `Paired ${device.label} to ${world?.name || 'world'}`, { deviceId: id, worldId: device.worldId }); return device;
  }

  byToken(token) { return Object.values(this.state.devices).find(d => d.token === token); }
  safeDevices() { return Object.values(this.state.devices).map(({ token, ...device }) => device); }

  async createUser({ username, password, role = 'user' }) {
    const name = cleanUsername(username);
    if (!/^[a-z0-9_.-]{3,32}$/.test(name)) throw new Error('Username must be 3-32 characters using letters, numbers, _, . or -');
    if (Object.values(this.state.users).some(u => u.username === name)) throw new Error('Username already exists');
    if (typeof password !== 'string' || password.length < 12) throw new Error('Password must be at least 12 characters');
    if (bcrypt.truncates(password)) throw new Error('Password is too long for bcrypt (72 UTF-8 bytes maximum)');
    const id = crypto.randomUUID();
    this.state.users[id] = { id, username: name, passwordHash: await bcrypt.hash(password, 12), role: role === 'admin' ? 'admin' : 'user', enabled: true, createdAt: now(), updatedAt: now(), lastLogin: null };
    this.addActivity('account', `Created ${this.state.users[id].role} account ${name}`, { userId: id });
    return this.safeUser(this.state.users[id]);
  }

  safeUser(user) { if (!user) return null; const { passwordHash, ...safe } = user; return safe; }
  safeUsers() { return Object.values(this.state.users).map(u => this.safeUser(u)).sort((a, b) => a.username.localeCompare(b.username)); }
  userCount() { return Object.keys(this.state.users).length; }
  adminCount() { return Object.values(this.state.users).filter(u => u.role === 'admin' && u.enabled).length; }

  async authenticate(username, password) {
    const name = cleanUsername(username); const user = Object.values(this.state.users).find(u => u.username === name);
    if (!user || !user.enabled || typeof password !== 'string') return null;
    if (!(await bcrypt.compare(password, user.passwordHash))) return null;
    user.lastLogin = now(); user.updatedAt = now(); this.save(); return this.safeUser(user);
  }

  createSession(userId, ttlMs = 7 * 24 * 60 * 60 * 1000) {
    const raw = crypto.randomBytes(32).toString('base64url'); const hash = sessionHash(raw);
    this.state.sessions[hash] = { userId, createdAt: now(), expiresAt: now() + ttlMs }; this.pruneSessions(false); this.save(); return raw;
  }

  sessionUser(raw) {
    if (!raw) return null; const session = this.state.sessions[sessionHash(raw)];
    if (!session || session.expiresAt <= now()) return null;
    const user = this.state.users[session.userId]; if (!user?.enabled) return null; return this.safeUser(user);
  }

  destroySession(raw) { if (raw) delete this.state.sessions[sessionHash(raw)]; this.save(); }
  pruneSessions(save = true) { const t = now(); for (const [k, s] of Object.entries(this.state.sessions)) if (!s || s.expiresAt <= t || !this.state.users[s.userId]?.enabled) delete this.state.sessions[k]; if (save) this.save(); }
  destroyUserSessions(userId) { for (const [k, s] of Object.entries(this.state.sessions)) if (s.userId === userId) delete this.state.sessions[k]; this.save(); }

  async updateUser(id, patch, actorId) {
    const user = this.state.users[id]; if (!user) throw new Error('User not found');
    if (patch.role && ['admin', 'user'].includes(patch.role)) {
      if (user.role === 'admin' && patch.role !== 'admin' && this.adminCount() <= 1) throw new Error('CCNexus must keep at least one enabled admin');
      user.role = patch.role;
    }
    if (patch.enabled !== undefined) {
      const enabled = Boolean(patch.enabled);
      if (user.role === 'admin' && !enabled && this.adminCount() <= 1) throw new Error('CCNexus must keep at least one enabled admin');
      user.enabled = enabled; if (!enabled) this.destroyUserSessions(id);
    }
    if (patch.password) {
      if (String(patch.password).length < 12 || bcrypt.truncates(String(patch.password))) throw new Error('Password must be 12-72 UTF-8 bytes');
      user.passwordHash = await bcrypt.hash(String(patch.password), 12); this.destroyUserSessions(id);
    }
    user.updatedAt = now(); this.addActivity('account', `Updated account ${user.username}`, { userId: id, actorId }); return this.safeUser(user);
  }

  deleteUser(id, actorId) {
    const user = this.state.users[id]; if (!user) throw new Error('User not found');
    if (id === actorId) throw new Error('You cannot delete the account you are currently using');
    if (user.role === 'admin' && this.adminCount() <= 1) throw new Error('CCNexus must keep at least one enabled admin');
    delete this.state.users[id]; this.destroyUserSessions(id); this.addActivity('account', `Deleted account ${user.username}`, { userId: id, actorId });
  }

  mediaState(worldId) {
    this.state.media[worldId] ||= { queue: [], current: null, status: 'idle', volume: 1, updatedAt: now() };
    return this.state.media[worldId];
  }
}
