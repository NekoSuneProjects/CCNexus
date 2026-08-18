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
      const mod = require('text2wav');
      if (typeof mod !== 'function') throw new Error('text2wav did not export a synthesis function');
      return mod;
    });
  }
  return enginePromise;
}

export async function synthesizeCpuTts(text, options = {}) {
  const input = String(text || '').trim();
  if (!input) throw new Error('TTS text is empty');

  const text2wav = await loadEngine();
  const voice = String(options.voice || 'en').trim() || 'en';
  const speed = Math.round(clamp(options.rate, 80, 450, 165));
  const amplitude = Math.round(clamp(options.amplitude, 0, 200, 100));
  const pitch = Math.round(clamp(options.pitch, 0, 99, 50));

  const wav = await text2wav(input, {
    voice,
    speed,
    amplitude,
    pitch,
    encoding: 1
  });

  if (!wav || !wav.length) throw new Error('CPU TTS engine returned no WAV audio');
  return Buffer.from(wav);
}

export function ttsEngineStatus() {
  return {
    engine: 'text2wav/espeak-ng-wasm',
    compute: 'cpu',
    gpuRequired: false
  };
}
