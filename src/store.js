import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';

export class Store {
  constructor(file) {
    this.file = file;
    fs.mkdirSync(path.dirname(file), { recursive: true });
    this.state = this.load();
  }

  fresh() {
    return {
      version: 1,
      adminToken: crypto.randomBytes(24).toString('hex'),
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

  save() { fs.writeFileSync(this.file, JSON.stringify(this.state, null, 2)); }
  token() { return process.env.CCNEXUS_ADMIN_TOKEN || this.state.adminToken; }

  addActivity(type, message, meta = {}) {
    this.state.activity.unshift({ id: crypto.randomUUID(), type, message, meta, at: Date.now() });
    this.state.activity = this.state.activity.slice(0, 150);
    this.save();
  }

  createPairCode() {
    const code = String(Math.floor(100000 + Math.random() * 900000));
    this.state.pairingCodes[code] = Date.now() + 10 * 60 * 1000;
    this.save();
    return code;
  }

  consumePairCode(code) {
    const expiry = this.state.pairingCodes[String(code)];
    delete this.state.pairingCodes[String(code)];
    this.save();
    return Boolean(expiry && expiry > Date.now());
  }

  pairDevice(input) {
    const token = crypto.randomBytes(24).toString('hex');
    const id = crypto.randomUUID();
    const device = {
      id, token,
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
    this.addActivity('device', `Paired ${device.label}`);
    return device;
  }

  byToken(token) { return Object.values(this.state.devices).find(d => d.token === token); }
  safeDevices() { return Object.values(this.state.devices).map(({ token, ...device }) => device); }
}
