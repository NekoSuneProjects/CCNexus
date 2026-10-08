import fs from 'node:fs';
import path from 'node:path';
import Database from 'better-sqlite3';
import mysql from 'mysql2/promise';
import pg from 'pg';
import { MongoClient } from 'mongodb';

const { Pool } = pg;
const CONFIG_NAME = 'config.json';

function cleanType(type) {
  const t = String(type || 'sqlite').toLowerCase();
  if (t === 'mariadb') return 'mysql';
  if (!['sqlite', 'mysql', 'postgres', 'mongodb'].includes(t)) throw new Error('Unsupported database type');
  return t;
}

export function configPath(dataDir) { return path.join(dataDir, CONFIG_NAME); }

export function loadInstallConfig(dataDir) {
  try { return JSON.parse(fs.readFileSync(configPath(dataDir), 'utf8')); }
  catch { return null; }
}

export function saveInstallConfig(dataDir, config) {
  fs.mkdirSync(dataDir, { recursive: true });
  const target = configPath(dataDir);
  const tmp = `${target}.tmp`;
  fs.writeFileSync(tmp, JSON.stringify(config, null, 2), { mode: 0o600 });
  fs.renameSync(tmp, target);
  try { fs.chmodSync(target, 0o600); } catch {}
}

export function safeDatabaseInfo(config = {}) {
  const type = cleanType(config.type || 'sqlite');
  if (type === 'sqlite') return { type, file: config.file || 'ccnexus.sqlite' };
  if (type === 'mongodb') return { type, host: config.host || '', port: Number(config.port || 27017), database: config.database || 'ccnexus', uriConfigured: Boolean(config.uri) };
  return { type, host: config.host || '', port: Number(config.port || (type === 'postgres' ? 5432 : 3306)), database: config.database || 'ccnexus', user: config.user || '', ssl: Boolean(config.ssl) };
}

function sqliteFile(config, dataDir) {
  const value = String(config.file || 'ccnexus.sqlite').trim() || 'ccnexus.sqlite';
  return path.isAbsolute(value) ? value : path.join(dataDir, value);
}

class SQLiteAdapter {
  constructor(config, dataDir) { this.config = config; this.file = sqliteFile(config, dataDir); this.db = null; }
  async init() {
    fs.mkdirSync(path.dirname(this.file), { recursive: true });
    this.db = new Database(this.file);
    this.db.pragma('journal_mode = WAL');
    this.db.pragma('foreign_keys = ON');
    this.db.prepare('CREATE TABLE IF NOT EXISTS ccnexus_state (id INTEGER PRIMARY KEY CHECK (id = 1), payload TEXT NOT NULL, updated_at INTEGER NOT NULL)').run();
  }
  async loadState() { const row = this.db.prepare('SELECT payload FROM ccnexus_state WHERE id = 1').get(); return row ? JSON.parse(row.payload) : null; }
  async saveState(state) {
    const payload = JSON.stringify(state);
    this.db.prepare('INSERT INTO ccnexus_state (id,payload,updated_at) VALUES (1,?,?) ON CONFLICT(id) DO UPDATE SET payload=excluded.payload, updated_at=excluded.updated_at').run(payload, Date.now());
  }
  async ping() { return this.db.prepare('SELECT 1 AS ok').get()?.ok === 1; }
  async close() { this.db?.close(); this.db = null; }
  info() { return { type: 'sqlite', file: this.file }; }
}

class MySQLAdapter {
  constructor(config) { this.config = config; this.pool = null; }
  async init() {
    this.pool = mysql.createPool({ host: this.config.host || '127.0.0.1', port: Number(this.config.port || 3306), user: this.config.user, password: this.config.password || '', database: this.config.database || 'ccnexus', waitForConnections: true, connectionLimit: 5, ssl: this.config.ssl ? {} : undefined });
    await this.pool.query('CREATE TABLE IF NOT EXISTS ccnexus_state (id TINYINT PRIMARY KEY, payload LONGTEXT NOT NULL, updated_at BIGINT NOT NULL)');
  }
  async loadState() { const [rows] = await this.pool.query('SELECT payload FROM ccnexus_state WHERE id = 1'); return rows[0] ? JSON.parse(rows[0].payload) : null; }
  async saveState(state) { await this.pool.execute('INSERT INTO ccnexus_state (id,payload,updated_at) VALUES (1,?,?) ON DUPLICATE KEY UPDATE payload=VALUES(payload), updated_at=VALUES(updated_at)', [JSON.stringify(state), Date.now()]); }
  async ping() { const [rows] = await this.pool.query('SELECT 1 AS ok'); return Number(rows[0]?.ok) === 1; }
  async close() { await this.pool?.end(); this.pool = null; }
  info() { return safeDatabaseInfo({ ...this.config, type: 'mysql' }); }
}

class PostgresAdapter {
  constructor(config) { this.config = config; this.pool = null; }
  async init() {
    this.pool = new Pool({ host: this.config.host || '127.0.0.1', port: Number(this.config.port || 5432), user: this.config.user, password: this.config.password || '', database: this.config.database || 'ccnexus', ssl: this.config.ssl ? { rejectUnauthorized: this.config.rejectUnauthorized !== false } : false, max: 5 });
    await this.pool.query('CREATE TABLE IF NOT EXISTS ccnexus_state (id SMALLINT PRIMARY KEY, payload TEXT NOT NULL, updated_at BIGINT NOT NULL)');
  }
  async loadState() { const result = await this.pool.query('SELECT payload FROM ccnexus_state WHERE id = 1'); return result.rows[0] ? JSON.parse(result.rows[0].payload) : null; }
  async saveState(state) { await this.pool.query('INSERT INTO ccnexus_state (id,payload,updated_at) VALUES (1,$1,$2) ON CONFLICT(id) DO UPDATE SET payload=EXCLUDED.payload, updated_at=EXCLUDED.updated_at', [JSON.stringify(state), Date.now()]); }
  async ping() { const result = await this.pool.query('SELECT 1 AS ok'); return Number(result.rows[0]?.ok) === 1; }
  async close() { await this.pool?.end(); this.pool = null; }
  info() { return safeDatabaseInfo({ ...this.config, type: 'postgres' }); }
}

function mongoUri(config) {
  if (config.uri) return String(config.uri);
  const host = config.host || '127.0.0.1';
  const port = Number(config.port || 27017);
  const user = config.user ? encodeURIComponent(config.user) : '';
  const pass = config.password ? `:${encodeURIComponent(config.password)}` : '';
  const auth = user ? `${user}${pass}@` : '';
  return `mongodb://${auth}${host}:${port}`;
}

class MongoAdapter {
  constructor(config) { this.config = config; this.client = null; this.collection = null; }
  async init() {
    this.client = new MongoClient(mongoUri(this.config), { serverSelectionTimeoutMS: 7000 });
    await this.client.connect();
    const db = this.client.db(this.config.database || 'ccnexus');
    this.collection = db.collection('ccnexus_state');
    await db.command({ ping: 1 });
  }
  async loadState() { const row = await this.collection.findOne({ _id: 'state' }); return row?.payload || null; }
  async saveState(state) { await this.collection.updateOne({ _id: 'state' }, { $set: { payload: state, updatedAt: new Date() } }, { upsert: true }); }
  async ping() { return Boolean(await this.client.db(this.config.database || 'ccnexus').command({ ping: 1 })); }
  async close() { await this.client?.close(); this.client = null; }
  info() { return safeDatabaseInfo({ ...this.config, type: 'mongodb' }); }
}

export async function openDatabase(config, dataDir) {
  const type = cleanType(config?.type);
  const adapter = type === 'sqlite' ? new SQLiteAdapter(config, dataDir)
    : type === 'mysql' ? new MySQLAdapter(config)
      : type === 'postgres' ? new PostgresAdapter(config)
        : new MongoAdapter(config);
  await adapter.init();
  return adapter;
}

export async function testDatabase(config, dataDir) {
  const adapter = await openDatabase(config, dataDir);
  try { await adapter.ping(); return adapter.info(); }
  finally { await adapter.close(); }
}
