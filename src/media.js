import crypto from 'node:crypto';
import { spawn } from 'node:child_process';
import { WebSocket } from 'ws';

function clamp(v, min, max, fallback) { const n = Number(v); return Number.isFinite(n) ? Math.max(min, Math.min(max, n)) : fallback; }
function isYoutube(url) { return /^(https?:\/\/)?(www\.)?(youtube\.com|youtu\.be)\//i.test(String(url || '')); }

export class MediaManager {
  constructor({ store, send, socketFor }) {
    this.store = store;
    this.send = send;
    this.socketFor = socketFor;
    this.active = new Map();
  }

  state(worldId) {
    const s = this.store.mediaState(worldId);
    return { ...s, queue: [...s.queue], current: s.current ? { ...s.current } : null };
  }

  normalizeItem(input, deviceIds = []) {
    const type = ['url', 'radio', 'tts'].includes(input.type) ? input.type : 'url';
    const item = {
      id: crypto.randomUUID(), type,
      title: String(input.title || '').trim().slice(0, 160),
      url: String(input.url || '').trim().slice(0, 3000),
      text: String(input.text || '').trim().slice(0, 600),
      voice: String(input.voice || 'en').trim().replace(/[^a-zA-Z0-9_+\-]/g, '').slice(0, 40) || 'en',
      rate: Math.round(clamp(input.rate, 80, 450, 165)),
      volume: clamp(input.volume, 0, 3, 1),
      deviceIds: [...new Set(deviceIds.map(String))],
      createdAt: Date.now()
    };
    if (type === 'tts' && !item.text) throw new Error('TTS text is required');
    if (type !== 'tts' && !/^https?:\/\//i.test(item.url)) throw new Error('A valid http(s) media URL is required');
    if (!item.title) item.title = type === 'tts' ? item.text.slice(0, 60) : type === 'radio' ? 'Radio stream' : isYoutube(item.url) ? 'YouTube' : 'Media stream';
    return item;
  }

  async enqueue(worldId, input, deviceIds) {
    const item = this.normalizeItem(input, deviceIds);
    const s = this.store.mediaState(worldId);
    s.queue.push(item); s.updatedAt = Date.now(); this.store.save();
    if (input.autoplay !== false && !this.active.has(worldId) && s.status !== 'paused') this.play(worldId).catch(err => this.fail(worldId, err));
    return item;
  }

  async play(worldId) {
    if (this.active.has(worldId)) return this.state(worldId);
    const s = this.store.mediaState(worldId);
    if (s.current && s.status === 'paused') return this.resume(worldId);
    const item = s.queue.shift();
    if (!item) { s.current = null; s.status = 'idle'; s.updatedAt = Date.now(); this.store.save(); return this.state(worldId); }
    const targets = item.deviceIds.filter(id => this.socketFor(id)?.readyState === WebSocket.OPEN);
    if (!targets.length) {
      s.current = null; s.status = 'idle'; s.updatedAt = Date.now(); this.store.addActivity('audio', `Skipped ${item.title}: no selected speaker nodes are online`, { worldId, mediaId: item.id });
      return this.play(worldId);
    }
    s.current = item; s.status = 'loading'; s.volume = item.volume; s.updatedAt = Date.now(); this.store.save();
    const job = await this.spawnItem(item, targets, worldId, false);
    this.active.set(worldId, job); s.status = 'playing'; s.updatedAt = Date.now(); this.store.save();
    this.store.addActivity('audio', `Playing ${item.title}`, { worldId, mediaId: item.id, type: item.type });
    job.done.finally(() => this.finish(worldId, job));
    return this.state(worldId);
  }

  async spawnItem(item, targets, worldId, transient) {
    let ff, source;
    const targetVolume = () => transient ? item.volume : this.store.mediaState(worldId).volume;
    if (item.type === 'tts') {
      source = spawn(process.env.TTS_BIN || 'espeak-ng', ['--stdout', '-v', item.voice, '-s', String(item.rate), item.text], { stdio: ['ignore', 'pipe', 'pipe'] });
      ff = spawn(process.env.FFMPEG_BIN || 'ffmpeg', ['-hide_banner', '-loglevel', 'error', '-i', 'pipe:0', '-vn', '-ac', '1', '-ar', '48000', '-f', 's8', 'pipe:1'], { stdio: ['pipe', 'pipe', 'pipe'] });
      source.stdout.pipe(ff.stdin);
    } else {
      let input = item.url;
      if (item.type === 'url' && isYoutube(item.url)) input = await this.resolveYoutube(item.url);
      ff = spawn(process.env.FFMPEG_BIN || 'ffmpeg', ['-hide_banner', '-loglevel', 'error', '-re', '-i', input, '-vn', '-ac', '1', '-ar', '48000', '-f', 's8', 'pipe:1'], { stdio: ['ignore', 'pipe', 'pipe'] });
    }
    let error = '';
    source?.stderr.on('data', d => error += d.toString()); ff.stderr.on('data', d => error += d.toString());
    for (const id of targets) this.send(id, { type: 'audio_stop' });
    ff.stdout.on('data', chunk => {
      for (let offset = 0; offset < chunk.length; offset += 32768) {
        const part = chunk.subarray(offset, Math.min(chunk.length, offset + 32768));
        const payload = JSON.stringify({ type: 'audio_chunk', volume: targetVolume(), data: part.toString('base64') });
        for (const id of targets) {
          const ws = this.socketFor(id);
          if (ws?.readyState === WebSocket.OPEN) ws.send(payload);
        }
      }
    });
    let resolveDone;
    const done = new Promise(resolve => { resolveDone = resolve; });
    const job = { id: item.id, item, targets, ffmpeg: ff, source, done, resolveDone, error: () => error, worldId, transient, autoNext: true, paused: false, closed: false };
    ff.on('error', e => { error += e.message; }); source?.on('error', e => { error += e.message; });
    ff.on('close', code => { if (job.closed) return; job.closed = true; for (const id of targets) this.send(id, { type: 'audio_end', ok: code === 0, error: error.slice(-300) }); resolveDone({ code, error }); });
    return job;
  }

  async resolveYoutube(url) {
    const yt = spawn(process.env.YTDLP_BIN || 'yt-dlp', ['-f', 'bestaudio', '--no-playlist', '-g', url], { stdio: ['ignore', 'pipe', 'pipe'] });
    let out = '', err = ''; yt.stdout.on('data', d => out += d.toString()); yt.stderr.on('data', d => err += d.toString());
    const code = await new Promise((resolve, reject) => { yt.on('close', resolve); yt.on('error', reject); });
    if (code !== 0 || !out.trim()) throw new Error(`yt-dlp failed: ${err.slice(-260)}`);
    return out.trim().split(/\r?\n/)[0];
  }

  finish(worldId, job) {
    if (job.transient) return;
    if (this.active.get(worldId) !== job) return;
    this.active.delete(worldId);
    const s = this.store.mediaState(worldId); s.current = null; s.status = 'idle'; s.updatedAt = Date.now(); this.store.save();
    if (job.autoNext) setTimeout(() => this.play(worldId).catch(err => this.fail(worldId, err)), 100);
  }

  fail(worldId, err) {
    console.error('[CCNexus audio]', err);
    const s = this.store.mediaState(worldId); s.current = null; s.status = 'error'; s.error = String(err?.message || err).slice(0, 300); s.updatedAt = Date.now(); this.store.save();
    this.store.addActivity('audio', `Audio error: ${s.error}`, { worldId });
    const job = this.active.get(worldId); if (job) { job.autoNext = false; this.kill(job); this.active.delete(worldId); }
  }

  pause(worldId) {
    const job = this.active.get(worldId); if (!job) return this.state(worldId);
    job.ffmpeg.stdout.pause(); job.paused = true; for (const id of job.targets) this.send(id, { type: 'audio_stop' });
    const s = this.store.mediaState(worldId); s.status = 'paused'; s.updatedAt = Date.now(); this.store.save(); return this.state(worldId);
  }

  resume(worldId) {
    const job = this.active.get(worldId); if (!job) return this.play(worldId);
    job.ffmpeg.stdout.resume(); job.paused = false; const s = this.store.mediaState(worldId); s.status = 'playing'; s.updatedAt = Date.now(); this.store.save(); return this.state(worldId);
  }

  stop(worldId, clearQueue = false) {
    const job = this.active.get(worldId); if (job) { job.autoNext = false; this.active.delete(worldId); this.kill(job); for (const id of job.targets) this.send(id, { type: 'audio_stop' }); }
    const s = this.store.mediaState(worldId); if (clearQueue) s.queue = []; s.current = null; s.status = 'idle'; s.updatedAt = Date.now(); this.store.save(); return this.state(worldId);
  }

  skip(worldId) {
    const job = this.active.get(worldId); if (job) { job.autoNext = true; this.kill(job); } else this.play(worldId).catch(err => this.fail(worldId, err)); return this.state(worldId);
  }

  setVolume(worldId, volume) { const s = this.store.mediaState(worldId); s.volume = clamp(volume, 0, 3, 1); if (s.current) s.current.volume = s.volume; s.updatedAt = Date.now(); this.store.save(); return this.state(worldId); }

  removeQueueItem(worldId, itemId) { const s = this.store.mediaState(worldId); s.queue = s.queue.filter(i => i.id !== itemId); s.updatedAt = Date.now(); this.store.save(); return this.state(worldId); }

  kill(job) { try { job.source?.kill('SIGKILL'); } catch {} try { job.ffmpeg?.kill('SIGKILL'); } catch {} }

  async announce(worldId, text, deviceIds, options = {}) {
    const targets = [...new Set(deviceIds)].filter(id => this.socketFor(id)?.readyState === WebSocket.OPEN);
    if (!targets.length) return { ok: false, reason: 'no-speakers' };
    const current = this.active.get(worldId); const wasPlaying = current && !current.paused;
    if (wasPlaying) { current.ffmpeg.stdout.pause(); for (const id of current.targets) this.send(id, { type: 'audio_stop' }); }
    const item = this.normalizeItem({ type: 'tts', text, title: 'Announcement', voice: options.voice || 'en', rate: options.rate || 165, volume: options.volume ?? 1.15 }, targets);
    const transient = await this.spawnItem(item, targets, worldId, true); await transient.done;
    if (wasPlaying && this.active.get(worldId) === current) current.ffmpeg.stdout.resume();
    return { ok: true };
  }
}
