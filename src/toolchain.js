import fs from 'node:fs';
import fsp from 'node:fs/promises';
import path from 'node:path';
import { spawn } from 'node:child_process';
import AdmZip from 'adm-zip';

const NIGHTLY_API = 'https://api.github.com/repos/yt-dlp/yt-dlp-nightly-builds/releases/latest';
const DENO_API = 'https://api.github.com/repos/denoland/deno/releases/latest';
const USER_AGENT = 'CCNexus/0.3 (+https://github.com/NekoSuneProjects/CCNexus)';
const NIGHTLY_VERSION_RE = /^\d{4}\.\d{2}\.\d{2}\.\d{6}$/;

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
    this.cookiesFile = process.env.YTDLP_COOKIES_FILE || path.join(dataDir, 'youtube-cookies.txt');
    this.ytdlpChannel = String(process.env.YTDLP_CHANNEL || 'nightly').trim() || 'nightly';
    this.preparePromise = null;
    this.info = { ytdlp: null, deno: null, cookies: null };
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
    this.prepareCookies();
    if (errors.length) console.warn(`[CCNexus media tools] ${errors.join(' | ')}`);
    return this.status();
  }

  async ytDlpVersion() {
    const v = await run(this.ytdlp, ['--version'], 20_000);
    if (v.code !== 0) throw new Error(v.stderr || 'yt-dlp --version failed');
    return v.stdout.split(/\r?\n/)[0].trim();
  }

  async prepareYtDlp() {
    if (process.env.YTDLP_BIN) {
      const version = await this.ytDlpVersion();
      this.info.ytdlp = { path: this.ytdlp, version, source: 'environment', channel: 'external', verified: false };
      return;
    }

    const channel = this.ytdlpChannel;
    if (!fs.existsSync(this.ytdlp)) {
      if (channel === 'nightly') await this.downloadYtDlpNightly();
      else throw new Error(`managed yt-dlp is missing and automatic download only supports the nightly channel (requested ${channel})`);
    }

    let version = await this.ytDlpVersion();
    if (channel === 'nightly' && !NIGHTLY_VERSION_RE.test(version)) {
      console.warn(`[CCNexus media tools] Managed yt-dlp ${version} is not a nightly build; replacing it with the official nightly binary`);
      await this.downloadYtDlpNightly();
      version = await this.ytDlpVersion();
    }

    let expectedVersion = null;
    if (enabled('YTDLP_AUTO_UPDATE', true)) {
      const update = await run(this.ytdlp, ['--update-to', channel], 180_000);
      if (update.code !== 0) console.warn(`[CCNexus media tools] yt-dlp ${channel} update check failed: ${update.stderr || update.stdout}`);
      version = await this.ytDlpVersion();

      if (channel === 'nightly') {
        try {
          const release = await fetchJson(NIGHTLY_API);
          expectedVersion = String(release.tag_name || '').trim() || null;
          if (expectedVersion && version !== expectedVersion) {
            console.warn(`[CCNexus media tools] yt-dlp nightly mismatch: installed ${version}, latest ${expectedVersion}; downloading the official nightly asset directly`);
            await this.downloadYtDlpNightly(release);
            version = await this.ytDlpVersion();
          }
        } catch (err) {
          console.warn(`[CCNexus media tools] Could not verify latest nightly tag: ${err.message}`);
        }
      }
    }

    const nightlyShape = channel === 'nightly' && NIGHTLY_VERSION_RE.test(version);
    const verified = channel === 'nightly' ? nightlyShape && (!expectedVersion || version === expectedVersion) : true;
    if (channel === 'nightly' && !nightlyShape) throw new Error(`managed yt-dlp version ${version} is not a nightly build`);
    this.info.ytdlp = { path: this.ytdlp, version, source: 'managed', channel, verified, expectedVersion };
  }

  async downloadYtDlpNightly(release = null) {
    console.log('[CCNexus media tools] Downloading official yt-dlp nightly...');
    release ||= await fetchJson(NIGHTLY_API);
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

  prepareCookies() {
    if (!fs.existsSync(this.cookiesFile)) {
      this.info.cookies = { enabled: false };
      return;
    }
    try {
      const first = fs.readFileSync(this.cookiesFile, 'utf8').split(/\r?\n/, 1)[0].trim();
      const netscape = first === '# Netscape HTTP Cookie File' || first === '# HTTP Cookie File';
      if (!netscape) console.warn(`[CCNexus media tools] ${this.cookiesFile} does not appear to be a Netscape-format cookies file`);
      this.info.cookies = { enabled: true, path: this.cookiesFile, netscape };
    } catch (err) {
      this.info.cookies = { enabled: false, error: err.message };
      console.warn(`[CCNexus media tools] Cannot read YouTube cookies file: ${err.message}`);
    }
  }

  async youtubeArgs() {
    await this.prepare();
    const remote = String(process.env.YTDLP_REMOTE_COMPONENTS || 'ejs:github').trim();
    const client = String(process.env.YTDLP_YOUTUBE_CLIENT || 'mweb').trim();
    const args = [];
    if (remote) args.push('--remote-components', remote);
    if (this.info.deno?.path) args.push('--js-runtimes', `deno:${this.info.deno.path}`);
    if (this.info.cookies?.enabled) args.push('--cookies', this.cookiesFile);
    if (client) args.push('--extractor-args', `youtube:player_client=${client}`);
    return args;
  }

  status() { return { ytdlp: this.info.ytdlp, deno: this.info.deno, cookies: this.info.cookies }; }
}
