/**
 * Tum TTS modellerini ayni metin ve ses ile calistirip karsilastirir.
 *
 *   node src/compare-models.ts
 *   node src/compare-models.ts --voice Kore --text "Kisa bir test"
 *
 * Cikti: out/compare/<model>.wav + konsolda gecikme/sure tablosu
 */
import { GoogleGenAI } from '@google/genai';
import { mkdirSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { requireApiKey } from './env.ts';
import { pcmDuration, toPlayableAudio } from './wav.ts';

function arg(name: string, fallback: string): string {
  const i = process.argv.indexOf(`--${name}`);
  return i !== -1 && process.argv[i + 1] ? process.argv[i + 1] : fallback;
}

const VOICE = arg('voice', 'Fola');
const TEXT = arg(
  'text',
  'Yapay zeka ses sentezi karsilastirma testi. Bu cumle tum modeller icin aynidir.',
);
const MODELS = [
  'gemini-3.8-flash-tts',
  'gemini-3.8-flash-lite-tts',
  'gemini-3.1-flash-tts-preview',
  'gemini-2.5-flash-preview-tts',
  'gemini-2.5-pro-preview-tts',
];

const ai = new GoogleGenAI({ apiKey: requireApiKey() });
const outDir = 'out/compare';
mkdirSync(outDir, { recursive: true });

interface Row {
  model: string;
  ok: boolean;
  ms: number;
  bytes: number;
  sec: number;
  note: string;
}

const rows: Row[] = [];

for (const model of MODELS) {
  process.stdout.write(`  ${model.padEnd(32)} ... `);
  const started = Date.now();
  try {
    const response = await ai.models.generateContent({
      model,
      config: {
        responseModalities: ['audio'],
        speechConfig: { voiceConfig: { prebuiltVoiceConfig: { voiceName: VOICE } } },
      },
      contents: [{ role: 'user', parts: [{ text: TEXT }] }],
    });

    const inline = response.candidates?.[0]?.content?.parts?.find((p) => p.inlineData)?.inlineData;
    if (!inline?.data) {
      rows.push({ model, ok: false, ms: Date.now() - started, bytes: 0, sec: 0, note: 'ses verisi yok' });
      console.log('SES YOK');
      continue;
    }

    const payload = Buffer.from(inline.data, 'base64');
    const result = toPlayableAudio(payload, inline.mimeType || '');

    // Sure, WAV basligi haric gercek PCM uzerinden hesaplanir
    const pcmBytes = result.action === 'wrapped' ? payload.byteLength : payload.byteLength - 44;
    const sec = pcmDuration(pcmBytes, result.options);

    const file = join(outDir, `${model}.wav`);
    writeFileSync(file, result.buffer);

    rows.push({ model, ok: true, ms: Date.now() - started, bytes: pcmBytes, sec, note: file });
    console.log(`OK  ${sec.toFixed(2)}sn  ${Date.now() - started}ms`);
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
    rows.push({ model, ok: false, ms: Date.now() - started, bytes: 0, sec: 0, note: msg.slice(0, 60) });
    console.log(`HATA: ${msg.slice(0, 70)}`);
  }
}

console.log(`\n=== ${VOICE} sesi, ayni metin (${TEXT.length} karakter) ===\n`);
console.log('  model'.padEnd(34) + 'durum   sure      gecikme    ses');
console.log('  ' + '-'.repeat(74));
for (const r of rows) {
  const status = r.ok ? 'OK  ' : 'HATA';
  console.log(
    `  ${r.model.padEnd(32)}${status}  ${r.sec.toFixed(2).padStart(6)}sn  ${String(r.ms).padStart(6)}ms  ${(r.bytes / 1024).toFixed(0).padStart(5)} KB` +
      (r.ok ? '' : `  ${r.note}`),
  );
}
