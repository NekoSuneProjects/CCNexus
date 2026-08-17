import fs from 'node:fs';
import fsp from 'node:fs/promises';
import path from 'node:path';
import { spawn } from 'node:child_process';
import AdmZip from 'adm-zip';

const NIGHTLY_API = 'https://api.github.com/repos/yt-dlp/yt-dlp-nightly-builds/releases/latest';
const DENO_API = 'https://api.github.com/repos/denoland/deno/releases/latest';
const USER_AGENT = 'CCNexus/0.3 (+https://github.com/NekoSuneProjects/CCNexus)';

function enabled(name, fallback = true) {
  const raw = process.env[name];
  if (raw == null || raw === '') return fallback;
  return !['0', 'false', 'no', 'off'].includes(String(raw).toLowerCase());
}

async function fetchJson(url) {
  const res = await fetch(url, { headers: { Accept: 'application/vnd.github+json', 'User-Agent': USER_AGENT } });
  if (!res.ok) throw new Error(`HTTP ${res.status} fetching ${url}`);
  return res.json();
}

async function download(url, destination) {
  const res = await fetch(url, { redirect: 'follow', headers: { 'User-Agent': USER_AGENT } });
  if (!res.ok || !res.body) throw new Error(`HTTP ${res.status} downloading ${url}`);
  await fsp.mkdir(path.dirname(destination), { recursive: true });
  const temp = `${destination}.download-${process.pid}`;
  const handle = await fsp.open(temp, 'w');
  try {
    for await (const chunk of res.body) await handle.write(chunk);
  } finally {
    await handle.close();
  }
  await fsp.rename(temp, destination);
  if (process.platform !== 'win32') await fsp.chmod(destination, 0o755);
}

function run(bin, args, timeoutMs = 120_000) {
  return new Promise((resolve, reject) => {
    const child = spawn(bin, args, { stdio: ['ignore', 'pipe', 'pipe'] });
    let stdout = '', stderr = '', settled = false;
    const timer = setTimeout(() => {
      if (settled) return;
      settled = true;
      try { child.kill('SIGKILL'); } catch {}
      reject(new Error(`${path.basename(bin)} timed out`));
    }, timeoutMs);
    child.stdout.on('data', d => stdout += d.toString());
    child.stderr.on('data', d => stderr += d.toString());
    child.on('error', err => {
      if (settled) return;
      settled = true; clearTimeout(timer); reject(err);
    });
    child.on('close', code => {
      if (settled) return;
      settled = true; clearTimeout(timer); resolve({ code, stdout: stdout.trim(), stderr: stderr.trim() });
    });
  });
}

function ytAssetName(assets = []) {
  if (process.platform === 'linux') {
    if (process.arch === 'x64' && assets.some(a => a.name === 'yt-dlp_linux')) return 'yt-dlp_linux';
    if (process.arch === 'arm64' && assets.some(a => a.name === 'yt-dlp_linux_aarch64')) return 'yt-dlp_linux_aarch64';
  }
  if (process.platform === 'win32') {
    if (process.arch === 'arm64' && assets.some(a => a.name === 'yt-dlp_arm64.exe')) return 'yt-dlp_arm64.exe';
    if (assets.some(a => a.name === 'yt-dlp.exe')) return 'yt-dlp.exe';
  }
  return assets.some(a => a.name === 'yt-dlp') ? 'yt-dlp' : null;
}

function denoAssetName() {
  if (process.platform === 'linux' && process.arch === 'x64') return 'deno-x86_64-unknown-linux-gnu.zip';
  if (process.platform === 'linux' && process.arch === 'arm64') return 'deno-aarch64-unknown-linux-gnu.zip';
  if (process.platform === 'win32' && process.arch === 'x64') return 'deno-x86_64-pc-windows-msvc.zip';
  if (process.platform === 'darwin' && process.arch === 'x64') return 'deno-x86_64-apple-darwin.zip';
  if (process.platform === 'darwin' && process.arch === 'arm64') return 'deno-aarch64-apple-darwin.zip';
  return null;
}

export class MediaToolchain {
  constructor({ dataDir }) {
    this.dataDir = dataDir;
    this.toolsDir = path.join(dataDir, 'tools');
    this.ytdlp = process.env.YTDLP_BIN || path.join(this.toolsDir, process.platform === 'win32' ? 'yt-dlp.exe' : 'yt-dlp');
    this.deno = process.env.DENO_BIN || path.join(this.toolsDir, process.platform === 'win32' ? 'deno.exe' : 'deno');
    this.preparePromise = null;
    this.info = { ytdlp: null, deno: null };
  }

  prepare() {
    if (!this.preparePromise) this.preparePromise = this._prepare().catch(err => {
      this.preparePromise = null;
      throw err;
    });
    return this.preparePromise;
  }

  async _prepare() {
    await fsp.mkdir(this.toolsDir, { recursive: true });
    const errors = [];
    try { await this.prepareYtDlp(); } catch (err) { errors.push(`yt-dlp: ${err.message}`); }
    try { await this.prepareDeno(); } catch (err) { errors.push(`Deno: ${err.message}`); }
    if (errors.length) console.warn(`[CCNexus media tools] ${errors.join(' | ')}`);
    return this.status();
  }

  async prepareYtDlp() {
    if (process.env.YTDLP_BIN) {
      const v = await run(this.ytdlp, ['--version'], 20_000);
      if (v.code !== 0) throw new Error(v.stderr || 'configured YTDLP_BIN failed');
      this.info.ytdlp = { path: this.ytdlp, version: v.stdout, source: 'environment' };
      return;
    }
    if (!fs.existsSync(this.ytdlp)) await this.downloadYtDlpNightly();
    if (enabled('YTDLP_AUTO_UPDATE', true)) {
      const channel = String(process.env.YTDLP_CHANNEL || 'nightly').trim() || 'nightly';
      const update = await run(this.ytdlp, ['--update-to', channel], 180_000);
      if (update.code !== 0) console.warn(`[CCNexus media tools] yt-dlp update check failed: ${update.stderr || update.stdout}`);
    }
    const v = await run(this.ytdlp, ['--version'], 20_000);
    if (v.code !== 0) throw new Error(v.stderr || 'downloaded yt-dlp failed');
    this.info.ytdlp = { path: this.ytdlp, version: v.stdout, source: 'managed-nightly' };
  }

  async downloadYtDlpNightly() {
    console.log('[CCNexus media tools] Downloading latest yt-dlp nightly...');
    const release = await fetchJson(NIGHTLY_API);
    const assetName = ytAssetName(release.assets || []);
    if (!assetName) throw new Error(`no compatible nightly asset for ${process.platform}/${process.arch}`);
    const asset = release.assets.find(a => a.name === assetName);
    await download(asset.browser_download_url, this.ytdlp);
  }

  async prepareDeno() {
    if (process.env.DENO_BIN) {
      const v = await run(this.deno, ['--version'], 20_000);
      if (v.code !== 0) throw new Error(v.stderr || 'configured DENO_BIN failed');
      this.info.deno = { path: this.deno, version: v.stdout.split(/\r?\n/)[0], source: 'environment' };
      return;
    }
    if (!fs.existsSync(this.deno)) {
      if (!enabled('DENO_AUTO_INSTALL', true)) throw new Error('Deno is missing and DENO_AUTO_INSTALL=false');
      await this.downloadDeno();
    }
    const v = await run(this.deno, ['--version'], 20_000);
    if (v.code !== 0) throw new Error(v.stderr || 'managed Deno failed');
    this.info.deno = { path: this.deno, version: v.stdout.split(/\r?\n/)[0], source: 'managed' };
  }

  async downloadDeno() {
    const wanted = denoAssetName();
    if (!wanted) throw new Error(`automatic Deno install does not support ${process.platform}/${process.arch}`);
    console.log('[CCNexus media tools] Downloading latest Deno runtime...');
    const release = await fetchJson(DENO_API);
    const asset = (release.assets || []).find(a => a.name === wanted);
    if (!asset) throw new Error(`Deno release asset ${wanted} was not found`);
    const zipPath = path.join(this.toolsDir, `.${wanted}`);
    await download(asset.browser_download_url, zipPath);
    try {
      const zip = new AdmZip(zipPath);
      const entry = zip.getEntries().find(e => path.basename(e.entryName).toLowerCase() === (process.platform === 'win32' ? 'deno.exe' : 'deno'));
      if (!entry) throw new Error('Deno executable missing from release archive');
      await fsp.writeFile(this.deno, entry.getData());
      if (process.platform !== 'win32') await fsp.chmod(this.deno, 0o755);
    } finally {
      await fsp.rm(zipPath, { force: true });
    }
  }

  async youtubeArgs() {
    await this.prepare();
    const remote = String(process.env.YTDLP_REMOTE_COMPONENTS || 'ejs:github').trim();
    const client = String(process.env.YTDLP_YOUTUBE_CLIENT || 'mweb').trim();
    const args = [];
    if (remote) args.push('--remote-components', remote);
    if (this.info.deno?.path) args.push('--js-runtimes', `deno:${this.info.deno.path}`);
    if (client) args.push('--extractor-args', `youtube:player_client=${client}`);
    return args;
  }

  status() { return { ytdlp: this.info.ytdlp, deno: this.info.deno }; }
}
