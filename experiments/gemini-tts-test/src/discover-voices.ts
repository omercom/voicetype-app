/**
 * 3.8 modellerinde gecerli ses adlarini bulur ve her biri icin kisa bir
 * ornek uretir. 2.5 modellerinin sesleri (achernar, kore, puck ...) ile
 * 3.8'in sesleri ayni degil, bu yuzden kesif gerekiyor.
 *
 *   node src/discover-voices.ts
 *   node src/discover-voices.ts --model gemini-3.8-flash-lite-tts
 */
import { GoogleGenAI } from '@google/genai';
import { mkdirSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { requireApiKey } from './env.ts';
import { toPlayableAudio } from './wav.ts';

function arg(name: string, fallback: string): string {
  const i = process.argv.indexOf(`--${name}`);
  return i !== -1 && process.argv[i + 1] ? process.argv[i + 1] : fallback;
}

const MODEL = arg('model', 'gemini-3.8-flash-tts');
const PROBE_TEXT = 'Merhaba, ben bir sesim.';
const DELAY_MS = Number(arg('delay', '4000'));
const RETRIES = Number(arg('retries', '3'));

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

/** Gecici hata (429/5xx) mi, yoksa gercekten gecersiz ses adi mi? */
function isTransient(msg: string): boolean {
  return /"code":429|"code":5\d\d|RESOURCE_EXHAUSTED|UNAVAILABLE|overloaded/i.test(msg);
}

/** 2.5 ailesinin bilinen sesleri + 3.8 ailesinde gorulen isimler. */
const CANDIDATES = [
  'Fola', 'Zephyr', 'Kore', 'Puck', 'Charon', 'Fenrir', 'Aoede', 'Leda',
  'Orus', 'Callirrhoe', 'Autonoe', 'Enceladus', 'Iapetus', 'Umbriel', 'Algieba',
  'Despina', 'Erinome', 'Algenib', 'Rasalgethi', 'Laomedeia', 'Achernar',
  'Alnilam', 'Schedar', 'Gacrux', 'Pulcherrima', 'Achird', 'Zubenelgenubi',
  'Vindemiatrix', 'Sadachbia', 'Sadaltager', 'Sulafat',
];

const ai = new GoogleGenAI({ apiKey: requireApiKey() });
const outDir = join('out', 'voices', MODEL);
mkdirSync(outDir, { recursive: true });

console.log(`\n=== ${MODEL} icin ses kesfi (${CANDIDATES.length} aday) ===\n`);

const valid: string[] = [];
const invalid: string[] = [];
const throttled: string[] = [];

for (const voice of CANDIDATES) {
  let done = false;

  for (let attempt = 1; attempt <= RETRIES && !done; attempt++) {
    try {
      const res = await ai.models.generateContent({
        model: MODEL,
        config: {
          responseModalities: ['audio'],
          speechConfig: { voiceConfig: { prebuiltVoiceConfig: { voiceName: voice } } },
        },
        contents: [{ role: 'user', parts: [{ text: PROBE_TEXT }] }],
      });
      const inline = res.candidates?.[0]?.content?.parts?.find((p) => p.inlineData)?.inlineData;
      if (inline?.data) {
        const payload = Buffer.from(inline.data, 'base64');
        const result = toPlayableAudio(payload, inline.mimeType || '');
        writeFileSync(join(outDir, `${voice}.wav`), result.buffer);
        valid.push(voice);
        console.log(`  [OK]    ${voice.padEnd(18)} ${(result.buffer.byteLength / 1024).toFixed(0)} KB`);
      } else {
        invalid.push(voice);
        console.log(`  [bos]   ${voice.padEnd(18)} ses verisi donmedi`);
      }
      done = true;
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err);
      const code = /\{"error":\{"code":(\d+)/.exec(msg)?.[1] || '?';

      if (isTransient(msg) && attempt < RETRIES) {
        console.log(`  [${code}]   ${voice.padEnd(18)} gecici hata, ${attempt}. deneme - bekleniyor...`);
        await sleep(DELAY_MS * attempt);
        continue;
      }
      if (isTransient(msg)) {
        throttled.push(voice);
        console.log(`  [${code}]   ${voice.padEnd(18)} kota nedeniyle test EDILEMEDI (gecersiz degil)`);
      } else {
        invalid.push(voice);
        console.log(`  [${code}]   ${voice.padEnd(18)} GECERSIZ: ${msg.slice(0, 60).replace(/\n/g, ' ')}`);
      }
      done = true;
    }
  }

  await sleep(DELAY_MS);
}

console.log(`\n=== Ozet: ${MODEL} ===`);
console.log(`  Gecerli (${valid.length}): ${valid.join(', ') || '(yok)'}`);
console.log(`  Gecersiz (${invalid.length}): ${invalid.join(', ') || '(yok)'}`);
if (throttled.length) {
  console.log(`  Kota nedeniyle belirsiz (${throttled.length}): ${throttled.join(', ')}`);
  console.log(`  -> Tekrar denemek icin: node src/discover-voices.ts --delay 8000`);
}
console.log(`  Ornekler: ${outDir}/`);
