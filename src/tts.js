import fs from 'node:fs';
import path from 'node:path';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
let enginePromise = null;

function clamp(value, min, max, fallback) {
  const n = Number(value);
  return Number.isFinite(n) ? Math.max(min, Math.min(max, n)) : fallback;
}

async function loadEngine() {
  if (!enginePromise) {
    enginePromise = Promise.resolve().then(() => {
      // text2wav's public wrapper lets its generated Emscripten loader discover
      // espeak-ng.wasm itself. On modern Node that first attempts fetch() with a
      // plain filesystem path (for example /home/container/node_modules/...),
      // which produces a noisy "Failed to parse URL" streaming warning before
      // falling back to ArrayBuffer instantiation. Preload the WASM bytes from
      // disk and pass Module.wasmBinary instead, so no fetch/streaming path is
      // attempted at all on Pterodactyl/Docker/standalone Node installations.
      const packageEntry = require.resolve('text2wav');
      const packageRoot = path.dirname(packageEntry);
      const factory = require(path.join(packageRoot, 'lib', 'espeak-ng.js'));
      if (typeof factory !== 'function') throw new Error('text2wav eSpeak-NG module did not export a factory');

      const wasmPath = path.join(packageRoot, 'lib', 'espeak-ng.wasm');
      const wasmBinary = new Uint8Array(fs.readFileSync(wasmPath));
      if (!wasmBinary.length) throw new Error('text2wav eSpeak-NG WASM binary is empty');

      return { factory, wasmBinary };
    });
  }
  return enginePromise;
}

function synthesizeWithModule(factory, wasmBinary, input, options) {
  return new Promise((resolve, reject) => {
    const args = [
      input,
      '-w wav.wav',
      '-v', options.voice,
      '-s', String(options.speed),
      '-a', String(options.amplitude),
      '-p', String(options.pitch),
      '-b', '1'
    ];

    const Module = {
      arguments: args,
      wasmBinary,
      onAbort: reason => reject(new Error(`eSpeak-NG WASM aborted: ${reason || 'unknown reason'}`)),
      postRun: function () {
        try {
          const wavFile = Module.FS?.root?.contents?.['wav.wav'];
          const wav = wavFile?.contents;
          if (!wav?.length) throw new Error('eSpeak-NG WASM produced no WAV data');
          try { Module.FS.unmount('/usr/share'); } catch {}
          resolve(Buffer.from(wav));
        } catch (err) {
          reject(err);
        }
      }
    };

    try {
      factory(Module);
    } catch (err) {
      reject(err);
    }
  });
}

export async function synthesizeCpuTts(text, options = {}) {
  const input = String(text || '').trim();
  if (!input) throw new Error('TTS text is empty');

  const { factory, wasmBinary } = await loadEngine();
  const voice = String(options.voice || 'en').trim() || 'en';
  const speed = Math.round(clamp(options.rate, 80, 450, 165));
  const amplitude = Math.round(clamp(options.amplitude, 0, 200, 100));
  const pitch = Math.round(clamp(options.pitch, 0, 99, 50));

  return synthesizeWithModule(factory, wasmBinary, input, { voice, speed, amplitude, pitch });
}

export function ttsEngineStatus() {
  return {
    engine: 'espeak-ng-wasm/preloaded',
    compute: 'cpu',
    gpuRequired: false,
    wasmLoading: 'filesystem'
  };
}
