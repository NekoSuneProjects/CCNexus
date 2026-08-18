import { spawn } from 'node:child_process';

const DEFAULT_INFO_API = 'https://dl.nekosunevr.co.uk/info';
const PREFERRED_FORMATS = ['251', '140', '250', '249', '18'];

function enabled(name, fallback = true) {
  const raw = process.env[name];
  if (raw == null || raw === '') return fallback;
  return !['0', 'false', 'no', 'off'].includes(String(raw).toLowerCase());
}

function cleanHeaders(value) {
  if (!value || typeof value !== 'object' || Array.isArray(value)) return {};
  const allowed = new Set(['user-agent', 'accept', 'accept-language', 'referer', 'origin']);
  const out = {};
  for (const [key, raw] of Object.entries(value)) {
    if (!allowed.has(String(key).toLowerCase()) || typeof raw !== 'string') continue;
    out[key] = raw.replace(/[\r\n]/g, '').slice(0, 2000);
  }
  return out;
}

function validFormat(format) {
  return Boolean(format && typeof format === 'object' && /^https?:\/\//i.test(String(format.url || '')) && format.has_drm !== true);
}

function isAudioOnly(format) {
  return validFormat(format) && String(format.vcodec || 'none') === 'none' && String(format.acodec || 'none') !== 'none';
}

function isMuxed(format) {
  return validFormat(format) && String(format.vcodec || 'none') !== 'none' && String(format.acodec || 'none') !== 'none';
}

function selectFormat(formats) {
  const usable = Array.isArray(formats) ? formats.filter(validFormat) : [];
  for (const id of PREFERRED_FORMATS) {
    const match = usable.find(format => String(format.format_id) === id && (id === '18' ? isMuxed(format) : isAudioOnly(format)));
    if (match) return match;
  }

  const audio = usable.filter(isAudioOnly).sort((a, b) => {
    const a48 = Number(a.asr) === 48000 ? 1 : 0;
    const b48 = Number(b.asr) === 48000 ? 1 : 0;
    return b48 - a48 || Number(b.abr || b.tbr || 0) - Number(a.abr || a.tbr || 0);
  });
  if (audio.length) return audio[0];

  return usable.filter(isMuxed).sort((a, b) => Number(b.abr || b.tbr || 0) - Number(a.abr || a.tbr || 0))[0] || null;
}

function run(bin, args, timeoutMs = 90_000) {
  return new Promise((resolve, reject) => {
    const child = spawn(bin, args, { stdio: ['ignore', 'pipe', 'pipe'] });
    let stdout = '', stderr = '', settled = false;
    const timer = setTimeout(() => {
      if (settled) return;
      settled = true;
      try { child.kill('SIGKILL'); } catch {}
      reject(new Error('yt-dlp timed out while resolving YouTube'));
    }, timeoutMs);
    child.stdout.on('data', chunk => stdout += chunk.toString());
    child.stderr.on('data', chunk => stderr += chunk.toString());
    child.on('error', err => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      reject(err);
    });
    child.on('close', code => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      resolve({ code, stdout: stdout.trim(), stderr: stderr.trim() });
    });
  });
}

export class YoutubeResolver {
  constructor({ tools }) {
    this.tools = tools;
    this.infoApi = String(process.env.CCNEXUS_YOUTUBE_INFO_API || DEFAULT_INFO_API).trim();
  }

  async resolve(url) {
    let remoteError = null;
    if (enabled('CCNEXUS_YOUTUBE_INFO_ENABLED', true) && this.infoApi) {
      try {
        const result = await this.resolveFromInfo(url);
        console.log(`[CCNexus YouTube] Neko downloader selected format ${result.formatId}${result.ext ? ` (${result.ext})` : ''}`);
        return result;
      } catch (err) {
        remoteError = err;
        console.warn(`[CCNexus YouTube] Neko downloader resolver unavailable: ${err.message}; falling back to local yt-dlp`);
      }
    }

    try {
      return await this.resolveLocal(url);
    } catch (err) {
      if (remoteError) throw new Error(`Neko downloader failed: ${remoteError.message}; local yt-dlp failed: ${err.message}`);
      throw err;
    }
  }

  async resolveFromInfo(url) {
    const endpoint = new URL(this.infoApi);
    endpoint.searchParams.set('url', url);
    endpoint.searchParams.set('flat', '1');
    endpoint.searchParams.set('fields', 'full');
    endpoint.searchParams.set('cache', '1');

    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), 20_000);
    let response;
    try {
      response = await fetch(endpoint, {
        headers: { Accept: 'application/json', 'User-Agent': 'CCNexus/0.3' },
        signal: controller.signal
      });
    } finally {
      clearTimeout(timer);
    }
    if (!response.ok) throw new Error(`info API returned HTTP ${response.status}`);

    const info = await response.json();
    const format = selectFormat(info?.formats);
    if (!format) throw new Error('info API returned no usable audio/media format');

    const headers = cleanHeaders(format.http_headers);
    if (enabled('CCNEXUS_YOUTUBE_INFO_PROBE', true)) await this.probe(format.url, headers);

    return {
      url: String(format.url),
      headers,
      source: 'nekosune-info',
      formatId: String(format.format_id || 'unknown'),
      ext: String(format.ext || ''),
      title: String(info?.title || '')
    };
  }

  async probe(url, headers) {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), 12_000);
    let response;
    try {
      response = await fetch(url, {
        method: 'GET',
        redirect: 'follow',
        headers: { ...headers, Range: 'bytes=0-1' },
        signal: controller.signal
      });
      if (!(response.ok || response.status === 206)) throw new Error(`signed media URL returned HTTP ${response.status} from this host`);
    } finally {
      clearTimeout(timer);
      try { await response?.body?.cancel(); } catch {}
    }
  }

  async resolveLocal(url) {
    const tools = await this.tools.prepare();
    if (!tools.ytdlp?.path) throw new Error('yt-dlp is unavailable; check the CCNexus media-tools startup log');
    const args = [
      ...(await this.tools.youtubeArgs()),
      '-f', 'bestaudio/best',
      '--no-playlist',
      '-g', url
    ];
    const result = await run(tools.ytdlp.path, args);
    if (result.code !== 0 || !result.stdout) throw new Error(result.stderr.slice(-500) || `yt-dlp exited with code ${result.code}`);
    return {
      url: result.stdout.split(/\r?\n/)[0],
      headers: {},
      source: 'local-yt-dlp',
      formatId: 'bestaudio/best',
      ext: '',
      title: ''
    };
  }
}
