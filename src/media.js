import crypto from 'node:crypto';
import path from 'node:path';
import { spawn } from 'node:child_process';
import { WebSocket } from 'ws';
import { MediaToolchain } from './toolchain.js';
import { YoutubeResolver } from './youtube-resolver.js';
import { synthesizeCpuTts, ttsEngineStatus } from './tts.js';

function clamp(v, min, max, fallback) { const n = Number(v); return Number.isFinite(n) ? Math.max(min, Math.min(max, n)) : fallback; }
function isYoutube(url) { return /^(https?:\/\/)?(www\.)?(youtube\.com|youtu\.be)\//i.test(String(url || '')); }
function ffmpegHeaders(headers = {}) {
  const lines = Object.entries(headers).filter(([, value]) => typeof value === 'string' && value).map(([key, value]) => `${key}: ${value}`);
  return lines.length ? `${lines.join('\r\n')}\r\n` : '';
}

// CC:Tweaked plays 48 kHz signed 8-bit PCM and only buffers one playAudio call
// at a time. Keep packets large enough to avoid stutter, while staying well
// below the default 128 KiB ComputerCraft websocket message limit after base64
// and JSON overhead are added.
const AUDIO_CHUNK_BYTES = Math.round(clamp(process.env.CCNEXUS_AUDIO_CHUNK_BYTES, 16 * 1024, 80 * 1024, 64 * 1024));
const RADIO_PREBUFFER_BYTES = Math.round(clamp(process.env.CCNEXUS_RADIO_PREBUFFER_BYTES, AUDIO_CHUNK_BYTES, 256 * 1024, 96 * 1024));

export class MediaManager {
  constructor({ store, send, socketFor }) {
    this.store = store;
    this.send = send;
    this.socketFor = socketFor;
    this.active = new Map();
    const dataDir = process.env.CCNEXUS_DATA_DIR || path.resolve(process.cwd(), 'data');
    this.tools = new MediaToolchain({ dataDir });
    this.youtube = new YoutubeResolver({ tools: this.tools });
    this.tools.prepare().then(info => {
      const yt = info.ytdlp
        ? `${info.ytdlp.channel === 'nightly' ? 'nightly ' : ''}${info.ytdlp.version}${info.ytdlp.verified ? ' [verified]' : ''}`
        : 'unavailable';
      const deno = info.deno ? `${info.deno.version}` : 'unavailable';
      console.log(`[CCNexus media tools] yt-dlp ${yt}; ${deno}`);
    }).catch(err => console.warn(`[CCNexus media tools] startup preparation failed: ${err.message}`));
    const tts = ttsEngineStatus();
    console.log(`[CCNexus TTS] ${tts.engine}; compute=${tts.compute}; gpuRequired=${tts.gpuRequired}`);

    // Audio PCM is only sent to selected speaker nodes. This tiny state sync is
    // broadcast to every online node in the workspace so Advanced Monitors can
    // show Now Playing even when the monitor computer is not a speaker target,
    // and so reconnecting/rebooted nodes recover the current stream state.
    this.stateSyncTimer = setInterval(() => {
      for (const [worldId, job] of this.active) {
        if (!job.transient) this.broadcastMediaState(worldId, { source: job.sourceName });
      }
    }, 2000);
    this.stateSyncTimer.unref?.();
  }

  state(worldId) {
    const s = this.store.mediaState(worldId);
    return { ...s, queue: [...s.queue], current: s.current ? { ...s.current } : null, tools: this.tools.status(), tts: ttsEngineStatus() };
  }

  worldNodeIds(worldId) {
    return Object.values(this.store.state.devices || {})
      .filter(device => device.worldId === worldId && this.socketFor(device.id)?.readyState === WebSocket.OPEN)
      .map(device => device.id);
  }

  broadcastMediaState(worldId, overrides = {}) {
    const s = this.store.mediaState(worldId);
    const current = overrides.current === undefined ? s.current : overrides.current;
    const status = String(overrides.status || s.status || 'idle').toLowerCase();
    const source = overrides.source || this.active.get(worldId)?.sourceName || (current?.type === 'tts' ? 'local-tts' : current?.type === 'radio' ? 'radio-stream' : current ? 'direct-media' : '-');
    const payload = {
      type: 'audio_state',
      status,
      title: status === 'idle' ? 'Nothing playing' : String(overrides.title || current?.title || 'Untitled media'),
      mediaType: status === 'idle' ? '-' : String(overrides.mediaType || current?.type || 'media'),
      source: status === 'idle' ? '-' : String(source || '-'),
      volume: clamp(overrides.volume ?? s.volume ?? current?.volume, 0, 3, 1),
      error: String(overrides.error || s.error || '').slice(0, 300),
      updatedAt: Date.now()
    };
    for (const id of this.worldNodeIds(worldId)) this.send(id, payload);
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
    if (!item) {
      s.current = null; s.status = 'idle'; s.updatedAt = Date.now(); this.store.save();
      this.broadcastMediaState(worldId, { status: 'idle', current: null });
      return this.state(worldId);
    }
    const targets = item.deviceIds.filter(id => this.socketFor(id)?.readyState === WebSocket.OPEN);
    if (!targets.length) {
      s.current = null; s.status = 'idle'; s.updatedAt = Date.now();
      this.store.addActivity('audio', `Skipped ${item.title}: no selected speaker nodes are online`, { worldId, mediaId: item.id });
      this.broadcastMediaState(worldId, { status: 'idle', current: null });
      return this.play(worldId);
    }
    s.current = item; s.status = 'loading'; s.volume = item.volume; s.error = ''; s.updatedAt = Date.now(); this.store.save();
    this.broadcastMediaState(worldId, { status: 'loading' });
    const job = await this.spawnItem(item, targets, worldId, false);
    this.active.set(worldId, job); s.status = 'playing'; s.updatedAt = Date.now(); this.store.save();
    this.broadcastMediaState(worldId, { status: 'playing', source: job.sourceName });
    this.store.addActivity('audio', `Playing ${item.title}`, { worldId, mediaId: item.id, type: item.type });
    job.done.finally(() => this.finish(worldId, job));
    return this.state(worldId);
  }

  async spawnItem(item, targets, worldId, transient) {
    let ff, source, resolved = null;
    const targetVolume = () => transient ? item.volume : this.store.mediaState(worldId).volume;
    if (item.type === 'tts') {
      const engine = String(process.env.CCNEXUS_TTS_ENGINE || 'wasm').trim().toLowerCase();
      if (engine === 'external') {
        source = spawn(process.env.TTS_BIN || 'espeak-ng', ['--stdout', '-v', item.voice, '-s', String(item.rate), item.text], { stdio: ['ignore', 'pipe', 'pipe'] });
        ff = spawn(process.env.FFMPEG_BIN || 'ffmpeg', ['-hide_banner', '-loglevel', 'error', '-i', 'pipe:0', '-vn', '-ac', '1', '-ar', '48000', '-f', 's8', 'pipe:1'], { stdio: ['pipe', 'pipe', 'pipe'] });
        source.stdout.pipe(ff.stdin);
        resolved = { source: 'external-tts' };
      } else {
        const wav = await synthesizeCpuTts(item.text, { voice: item.voice, rate: item.rate });
        ff = spawn(process.env.FFMPEG_BIN || 'ffmpeg', ['-hide_banner', '-loglevel', 'error', '-i', 'pipe:0', '-vn', '-ac', '1', '-ar', '48000', '-f', 's8', 'pipe:1'], { stdio: ['pipe', 'pipe', 'pipe'] });
        ff.stdin.end(wav);
        resolved = { source: 'cpu-wasm-tts' };
      }
    } else {
      let input = item.url;
      if (item.type === 'url' && isYoutube(item.url)) {
        resolved = await this.youtube.resolve(item.url);
        input = resolved.url;
        if ((!item.title || item.title === 'YouTube') && resolved.title) item.title = resolved.title.slice(0, 160);
      }
      const liveInput = item.type === 'radio';
      const inputArgs = liveInput
        ? ['-reconnect', '1', '-reconnect_at_eof', '1', '-reconnect_streamed', '1', '-reconnect_delay_max', '5']
        : ['-re'];
      const headerBlock = ffmpegHeaders(resolved?.headers);
      if (headerBlock) inputArgs.push('-headers', headerBlock);
      ff = spawn(process.env.FFMPEG_BIN || 'ffmpeg', [
        '-hide_banner', '-loglevel', 'error',
        ...inputArgs, '-i', input,
        '-vn', '-ac', '1', '-ar', '48000', '-f', 's8', 'pipe:1'
      ], { stdio: ['ignore', 'pipe', 'pipe'] });
    }

    let error = '';
    source?.stderr.on('data', d => error += d.toString());
    ff.stderr.on('data', d => error += d.toString());
    for (const id of targets) this.send(id, { type: 'audio_stop' });
    const sourceName = resolved?.source || (item.type === 'tts' ? 'local-tts' : item.type === 'radio' ? 'radio-stream' : 'direct-media');
    const meta = {
      type: 'audio_meta',
      title: item.title,
      mediaType: item.type,
      source: sourceName,
      volume: targetVolume()
    };
    // Keep the original metadata packet for speaker nodes. audio_state handles
    // workspace-wide monitor state without delivering PCM to monitor-only nodes.
    for (const id of targets) this.send(id, meta);

    const framer = this.createAudioFramer(targets, targetVolume, item.type === 'radio' ? RADIO_PREBUFFER_BYTES : AUDIO_CHUNK_BYTES);
    ff.stdout.on('data', chunk => framer.push(chunk));

    let resolveDone;
    const done = new Promise(resolve => { resolveDone = resolve; });
    const job = { id: item.id, item, targets, ffmpeg: ff, source, sourceName, framer, done, resolveDone, error: () => error, worldId, transient, autoNext: true, paused: false, closed: false };
    ff.on('error', e => { error += e.message; });
    source?.on('error', e => { error += e.message; });
    ff.on('close', code => {
      if (job.closed) return; job.closed = true;
      framer.flush();
      for (const id of targets) this.send(id, { type: 'audio_end', ok: code === 0, error: error.slice(-300) });
      resolveDone({ code, error });
    });
    return job;
  }

  createAudioFramer(targets, volumeFn, initialBufferBytes = AUDIO_CHUNK_BYTES) {
    let pending = Buffer.alloc(0);
    let started = initialBufferBytes <= 0;

    const emit = part => {
      if (!part.length) return;
      const payload = JSON.stringify({ type: 'audio_chunk', volume: volumeFn(), data: part.toString('base64') });
      for (const id of targets) {
        const ws = this.socketFor(id);
        if (ws?.readyState === WebSocket.OPEN) ws.send(payload);
      }
    };

    const drain = () => {
      if (!started) {
        if (pending.length < initialBufferBytes) return;
        started = true;
      }
      while (pending.length >= AUDIO_CHUNK_BYTES) {
        emit(pending.subarray(0, AUDIO_CHUNK_BYTES));
        pending = pending.subarray(AUDIO_CHUNK_BYTES);
      }
    };

    return {
      push: chunk => {
        if (!chunk?.length) return;
        pending = pending.length ? Buffer.concat([pending, chunk]) : Buffer.from(chunk);
        drain();
      },
      flush: () => {
        started = true;
        drain();
        if (pending.length) emit(pending);
        pending = Buffer.alloc(0);
      }
    };
  }

  sendAudioChunk(targets, chunk, volume) {
    for (let offset = 0; offset < chunk.length; offset += AUDIO_CHUNK_BYTES) {
      const part = chunk.subarray(offset, Math.min(chunk.length, offset + AUDIO_CHUNK_BYTES));
      const payload = JSON.stringify({ type: 'audio_chunk', volume, data: part.toString('base64') });
      for (const id of targets) {
        const ws = this.socketFor(id);
        if (ws?.readyState === WebSocket.OPEN) ws.send(payload);
      }
    }
  }

  finish(worldId, job) {
    if (job.transient || this.active.get(worldId) !== job) return;
    this.active.delete(worldId);
    const s = this.store.mediaState(worldId); s.current = null; s.status = 'idle'; s.updatedAt = Date.now(); this.store.save();
    this.broadcastMediaState(worldId, { status: 'idle', current: null });
    if (job.autoNext) setTimeout(() => this.play(worldId).catch(err => this.fail(worldId, err)), 100);
  }

  fail(worldId, err) {
    console.error('[CCNexus audio]', err);
    const s = this.store.mediaState(worldId); s.current = null; s.status = 'error'; s.error = String(err?.message || err).slice(0, 500); s.updatedAt = Date.now(); this.store.save();
    this.store.addActivity('audio', `Audio error: ${s.error}`, { worldId });
    const job = this.active.get(worldId); if (job) { job.autoNext = false; this.kill(job); this.active.delete(worldId); }
    this.broadcastMediaState(worldId, { status: 'error', current: null, error: s.error, title: 'Audio error' });
  }

  pause(worldId) {
    const job = this.active.get(worldId); if (!job) return this.state(worldId);
    job.ffmpeg.stdout.pause(); job.paused = true; for (const id of job.targets) this.send(id, { type: 'audio_stop' });
    const s = this.store.mediaState(worldId); s.status = 'paused'; s.updatedAt = Date.now(); this.store.save();
    this.broadcastMediaState(worldId, { status: 'paused', source: job.sourceName });
    return this.state(worldId);
  }

  resume(worldId) {
    const job = this.active.get(worldId); if (!job) return this.play(worldId);
    job.ffmpeg.stdout.resume(); job.paused = false;
    const s = this.store.mediaState(worldId); s.status = 'playing'; s.updatedAt = Date.now(); this.store.save();
    this.broadcastMediaState(worldId, { status: 'playing', source: job.sourceName });
    return this.state(worldId);
  }

  stop(worldId, clearQueue = false) {
    const job = this.active.get(worldId);
    if (job) { job.autoNext = false; this.active.delete(worldId); this.kill(job); for (const id of job.targets) this.send(id, { type: 'audio_stop' }); }
    const s = this.store.mediaState(worldId); if (clearQueue) s.queue = []; s.current = null; s.status = 'idle'; s.updatedAt = Date.now(); this.store.save();
    this.broadcastMediaState(worldId, { status: 'idle', current: null });
    return this.state(worldId);
  }

  skip(worldId) {
    const job = this.active.get(worldId); if (job) { job.autoNext = true; this.kill(job); } else this.play(worldId).catch(err => this.fail(worldId, err));
    return this.state(worldId);
  }

  setVolume(worldId, volume) {
    const s = this.store.mediaState(worldId); s.volume = clamp(volume, 0, 3, 1); if (s.current) s.current.volume = s.volume; s.updatedAt = Date.now(); this.store.save();
    const job = this.active.get(worldId);
    this.broadcastMediaState(worldId, { volume: s.volume, source: job?.sourceName });
    return this.state(worldId);
  }
  removeQueueItem(worldId, itemId) { const s = this.store.mediaState(worldId); s.queue = s.queue.filter(i => i.id !== itemId); s.updatedAt = Date.now(); this.store.save(); return this.state(worldId); }
  kill(job) { try { job.source?.kill('SIGKILL'); } catch {} try { job.ffmpeg?.kill('SIGKILL'); } catch {} }

  async chime(deviceIds, volume = 0.8) {
    const targets = [...new Set(deviceIds)].filter(id => this.socketFor(id)?.readyState === WebSocket.OPEN);
    if (!targets.length) return { ok: false, reason: 'no-speakers' };
    const ff = spawn(process.env.FFMPEG_BIN || 'ffmpeg', [
      '-hide_banner', '-loglevel', 'error', '-f', 'lavfi', '-i', 'sine=frequency=660:duration=0.16',
      '-f', 'lavfi', '-i', 'sine=frequency=880:duration=0.22',
      '-filter_complex', '[0:a]volume=0.08[a0];[1:a]volume=0.08[a1];[a0][a1]concat=n=2:v=0:a=1[out]',
      '-map', '[out]', '-ac', '1', '-ar', '48000', '-f', 's8', 'pipe:1'
    ], { stdio: ['ignore', 'pipe', 'pipe'] });
    let error = '';
    ff.stderr.on('data', d => error += d.toString()); ff.stdout.on('data', chunk => this.sendAudioChunk(targets, chunk, clamp(volume, 0, 3, 0.8)));
    const result = await new Promise(resolve => { ff.on('error', e => { error += e.message; resolve({ code: -1, error }); }); ff.on('close', code => resolve({ code, error })); });
    for (const id of targets) this.send(id, { type: 'audio_stop' });
    return { ok: result.code === 0, error: result.error.slice(-300) };
  }

  async announce(worldId, text, deviceIds, options = {}) {
    const targets = [...new Set(deviceIds)].filter(id => this.socketFor(id)?.readyState === WebSocket.OPEN);
    if (!targets.length) return { ok: false, reason: 'no-speakers' };
    const current = this.active.get(worldId); const wasPlaying = current && !current.paused;
    if (wasPlaying) { current.ffmpeg.stdout.pause(); for (const id of current.targets) this.send(id, { type: 'audio_stop' }); }
    if (options.chime !== false) await this.chime(targets, options.chimeVolume ?? 0.8);
    const item = this.normalizeItem({ type: 'tts', text, title: 'Announcement', voice: options.voice || 'en', rate: options.rate || 165, volume: options.volume ?? 1.15 }, targets);
    const transient = await this.spawnItem(item, targets, worldId, true); await transient.done;
    if (wasPlaying && this.active.get(worldId) === current) current.ffmpeg.stdout.resume();
    if (current && this.active.get(worldId) === current) this.broadcastMediaState(worldId, { status: current.paused ? 'paused' : 'playing', source: current.sourceName });
    return { ok: true };
  }
}
