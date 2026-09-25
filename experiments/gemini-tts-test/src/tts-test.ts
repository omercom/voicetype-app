/**
 * Gemini TTS denemesi.
 *
 * Kullanim ornekleri:
 *   node src/tts-test.ts
 *   node src/tts-test.ts --voice Kore --text "Merhaba dunya"
 *   node src/tts-test.ts --model gemini-3.8-flash-tts --out out/test.wav
 *   node src/tts-test.ts --text-file ./metin.txt --no-stream
 *   node src/tts-test.ts --raw        # ham parcalari da diske dok
 *
 * Onemli: API cagri tipine gore FARKLI bicim donduruyor. Bu script bicimi
 * mimeType'a guvenerek degil, baytlarin kendisine bakarak belirler (bkz. wav.ts).
 * Aksi halde streaming disi cagrilarda cift WAV basligi olusur.
 */
import { GoogleGenAI } from '@google/genai';
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { requireApiKey } from './env.ts';
import { humanBytes, isWav, parseMimeType, pcmDuration, toPlayableAudio } from './wav.ts';

// ---------------------------------------------------------------------------
// CLI argumanlari
// ---------------------------------------------------------------------------
function arg(name: string, fallback: string): string {
  const i = process.argv.indexOf(`--${name}`);
  return i !== -1 && process.argv[i + 1] ? process.argv[i + 1] : fallback;
}
const flag = (name: string) => process.argv.includes(`--${name}`);

const DEFAULT_TEXT =
  'Merhaba, bu Gemini metinden konusmaya donusturme sisteminin bir denemesidir. ' +
  'Sayilar: 2026, yuzde 42, saat 14:30. Tesekkurler.';

const MODEL = arg('model', 'gemini-3.8-flash-tts');
const VOICE = arg('voice', 'Fola');
const OUT = resolve(arg('out', `out/tts_${VOICE}_${Date.now()}.wav`));
const TEXT_FILE = arg('text-file', '');
const TEXT = TEXT_FILE ? readFileSync(resolve(TEXT_FILE), 'utf8') : arg('text', DEFAULT_TEXT);
const USE_STREAM = !flag('no-stream');
const SAVE_RAW = flag('raw');
const TEMPERATURE = Number(arg('temperature', '1'));

const ai = new GoogleGenAI({ apiKey: requireApiKey() });

console.log('\n=== Gemini TTS Denemesi ===');
console.log(`  model     : ${MODEL}`);
console.log(`  ses       : ${VOICE}`);
console.log(`  mod       : ${USE_STREAM ? 'generateContentStream' : 'generateContent'}`);
console.log(`  cikti     : ${OUT}`);
console.log(`  metin     : ${TEXT.slice(0, 80).replace(/\n/g, ' ')}${TEXT.length > 80 ? '...' : ''}`);
console.log('');

const started = Date.now();
const chunks: Buffer[] = [];
let declaredMime = '';
let textOut = '';
let chunkCount = 0;
let firstByteMs = 0;
let totalBytes = 0;

function handleInlineData(inlineData: { mimeType?: string | null; data?: string | null } | undefined) {
  if (!inlineData?.data) return;
  chunkCount++;
  declaredMime = inlineData.mimeType || declaredMime;

  const bytes = Buffer.from(inlineData.data, 'base64');
  if (firstByteMs === 0) firstByteMs = Date.now() - started;
  chunks.push(bytes);
  totalBytes += bytes.byteLength;

  if (SAVE_RAW) {
    const rawPath = `${OUT}.part${String(chunkCount).padStart(4, '0')}.bin`;
    mkdirSync(dirname(rawPath), { recursive: true });
    writeFileSync(rawPath, bytes);
  }
  process.stdout.write(`\r  [ses] ${chunkCount}. parca  +${humanBytes(bytes.byteLength)}  (toplam ${humanBytes(totalBytes)})      `);
}

if (!USE_STREAM) {
  // Streaming disi modda tek parca buyuk bir yuk gelir
  console.log('  (not: non-stream modda API genelde TAM bir WAV dondurur)\n');
}

try {
  if (USE_STREAM) {
    const stream = await ai.models.generateContentStream({
      model: MODEL,
      config: {
        temperature: TEMPERATURE,
        responseModalities: ['audio'],
        speechConfig: { voiceConfig: { prebuiltVoiceConfig: { voiceName: VOICE } } },
      },
      contents: [{ role: 'user', parts: [{ text: TEXT }] }],
    });
    for await (const chunk of stream) {
      for (const part of chunk.candidates?.[0]?.content?.parts ?? []) {
        if (part.inlineData) handleInlineData(part.inlineData);
        else if (part.text) textOut += part.text;
      }
    }
  } else {
    const res = await ai.models.generateContent({
      model: MODEL,
      config: {
        temperature: TEMPERATURE,
        responseModalities: ['audio'],
        speechConfig: { voiceConfig: { prebuiltVoiceConfig: { voiceName: VOICE } } },
      },
      contents: [{ role: 'user', parts: [{ text: TEXT }] }],
    });
    for (const part of res.candidates?.[0]?.content?.parts ?? []) {
      if (part.inlineData) handleInlineData(part.inlineData);
      else if (part.text) textOut += part.text;
    }
  }
} catch (err) {
  console.error(`\n[hata] ${err instanceof Error ? err.message : String(err)}`);
  console.error(`\n  Ipucu: model adini dogrulamak icin -> npm run models`);
  process.exit(1);
}

const elapsed = Date.now() - started;
console.log('');

if (textOut.trim()) console.log(`  [metin yaniti] ${textOut.trim()}`);

if (chunks.length === 0) {
  console.error('[hata] Yanitta hic ses verisi yok. Model adi/ses adi hatali olabilir.');
  console.error('       Dogrulamak icin: npm run models');
  process.exit(2);
}

// ---------------------------------------------------------------------------
// Bicim tespiti: mimeType'a DEGIL baytlara bakiyoruz
// ---------------------------------------------------------------------------
// Streaming'de her parca ham PCM'dir; birlestirip sonra sarmalariz.
// Non-stream'da tek parca zaten tam WAV olabilir.
const firstIsWav = isWav(chunks[0]);
const payload = Buffer.concat(chunks);

const result = toPlayableAudio(payload, declaredMime);

const finalPath = OUT.replace(/\.[^./\\]+$/, '') + '.' + result.extension;
mkdirSync(dirname(finalPath), { recursive: true });
writeFileSync(finalPath, result.buffer);

const duration = result.extension === 'wav' ? pcmDuration(result.buffer.byteLength - 44, result.options) : null;

console.log('\n=== Sonuc ===');
console.log(`  beyan edilen mime : ${declaredMime || '(bilinmiyor)'}`);
console.log(`  gercek icerik     : ${firstIsWav ? 'WAV (RIFF basligi var)' : 'ham PCM (basliksiz)'}`);
console.log(`  yapilan islem     : ${result.action === 'wrapped' ? 'WAV basligi eklendi' : 'oldugu gibi gecirildi'}`);
console.log(`  ses formati       : ${result.options.numChannels} kanal, ${result.options.sampleRate} Hz, ${result.options.bitsPerSample} bit`);
console.log(`  parca sayisi      : ${chunkCount}`);
console.log(`  ses verisi        : ${humanBytes(result.buffer.byteLength)}`);
if (duration) console.log(`  sure              : ${duration.toFixed(2)} sn`);
console.log(`  ilk ses gecikme   : ${firstByteMs} ms`);
console.log(`  toplam sure       : ${elapsed} ms`);
console.log(`  dosya             : ${finalPath}`);
console.log(`\n  Dinlemek icin : open "${finalPath}"`);
