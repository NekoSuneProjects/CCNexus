import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';

export class Store {
  constructor(file) {
    this.file = file;
    fs.mkdirSync(path.dirname(file), { recursive: true });
    this.state = this.load();
    this.migrate();
  }

  fresh() {
    return {
      version: 2,
      adminToken: crypto.randomBytes(24).toString('hex'),
      worlds: {},
      defaultWorldId: null,
      devices: {},
      pairingCodes: {},
      scenes: [],
      activity: []
    };
  }

  load() {
    try { return { ...this.fresh(), ...JSON.parse(fs.readFileSync(this.file, 'utf8')) }; }
    catch { const data = this.fresh(); fs.writeFileSync(this.file, JSON.stringify(data, null, 2)); return data; }
  }

  migrate() {
    this.state.worlds ||= {};
    this.state.devices ||= {};
    this.state.pairingCodes ||= {};
    if (!Object.keys(this.state.worlds).length) {
      this.state.worlds.default = {
        id: 'default', name: 'My Minecraft World', type: 'server', address: '', notes: '',
        createdAt: Date.now(), updatedAt: Date.now()
      };
      this.state.defaultWorldId = 'default';
    }
    if (!this.state.defaultWorldId || !this.state.worlds[this.state.defaultWorldId]) {
      this.state.defaultWorldId = Object.keys(this.state.worlds)[0];
    }
    for (const device of Object.values(this.state.devices)) {
      device.worldId ||= this.state.defaultWorldId;
      device.online = false;
      device.telemetry ||= {};
      device.peripherals ||= [];
    }
    this.state.version = 2;
    this.save();
  }

  save() { fs.writeFileSync(this.file, JSON.stringify(this.state, null, 2)); }
  token() { return process.env.CCNEXUS_ADMIN_TOKEN || this.state.adminToken; }

  addActivity(type, message, meta = {}) {
    this.state.activity.unshift({ id: crypto.randomUUID(), type, message, meta, at: Date.now() });
    this.state.activity = this.state.activity.slice(0, 300);
    this.save();
  }

  createWorld(input = {}) {
    const id = crypto.randomUUID();
    const world = {
      id,
      name: String(input.name || 'Minecraft World').trim().slice(0, 80),
      type: ['server', 'singleplayer', 'realm', 'other'].includes(input.type) ? input.type : 'server',
      address: String(input.address || '').trim().slice(0, 180),
      notes: String(input.notes || '').trim().slice(0, 500),
      createdAt: Date.now(), updatedAt: Date.now()
    };
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
    delete this.state.worlds[id];
    if (this.state.defaultWorldId === id) this.state.defaultWorldId = Object.keys(this.state.worlds)[0];
    this.addActivity('world', `Removed workspace ${world.name}`, { worldId: id });
    return { ok: true };
  }

  safeWorlds() {
    return Object.values(this.state.worlds).map(world => {
      const devices = Object.values(this.state.devices).filter(d => d.worldId === world.id);
      return {
        ...world,
        deviceCount: devices.length,
        onlineCount: devices.filter(d => d.online).length,
        lastSeen: devices.reduce((m, d) => Math.max(m, Number(d.lastSeen || 0)), 0) || null
      };
    });
  }

  createPairCode(worldId) {
    if (!this.state.worlds[worldId]) throw new Error('World/workspace not found');
    let code;
    do code = String(Math.floor(100000 + Math.random() * 900000)); while (this.state.pairingCodes[code]);
    this.state.pairingCodes[code] = { expiresAt: Date.now() + 10 * 60 * 1000, worldId };
    this.save();
    return code;
  }

  consumePairCode(code) {
    const entry = this.state.pairingCodes[String(code)];
    delete this.state.pairingCodes[String(code)];
    this.save();
    if (!entry) return null;
    if (typeof entry === 'number') return entry > Date.now() ? this.state.defaultWorldId : null;
    return entry.expiresAt > Date.now() && this.state.worlds[entry.worldId] ? entry.worldId : null;
  }

  pairDevice(input) {
    const token = crypto.randomBytes(24).toString('hex');
    const id = crypto.randomUUID();
    const device = {
      id, token,
      worldId: input.worldId || this.state.defaultWorldId,
      computerId: input.computerId,
      label: input.label || `Computer ${input.computerId}`,
      kind: input.kind || 'computer',
      online: false,
      peripherals: [],
      telemetry: {},
      createdAt: Date.now(),
      lastSeen: null
    };
    this.state.devices[id] = device;
    const world = this.state.worlds[device.worldId];
    this.addActivity('device', `Paired ${device.label} to ${world?.name || 'world'}`, { deviceId: id, worldId: device.worldId });
    return device;
  }

  byToken(token) { return Object.values(this.state.devices).find(d => d.token === token); }
  safeDevices() { return Object.values(this.state.devices).map(({ token, ...device }) => device); }
}
