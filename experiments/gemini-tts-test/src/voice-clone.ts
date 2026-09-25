/**
 * SES KLONLAMA (ReplicatedVoiceConfig).
 *
 * API'de `replicatedVoiceConfig` alani var: 24 kHz / 16-bit / mono ham PCM
 * ornegi verip o sesle konusturabiliyorsunuz.
 *
 * ETIK VE HUKUKI UYARI
 * --------------------
 * Bu script kendi sesinizle veya ACIK RIZASINI aldiginiz birinin sesiyle
 * kullanilmak uzere yazildi. Baskasinin sesini rizasi olmadan klonlamak:
 *   - Google'in Generative AI Prohibited Use Policy'sini ihlal eder
 *   - Kisi haklarini (sesin kisisel veri olmasi) ihlal eder
 *   - Taklit/dolandiricilik sucu kapsamina girebilir (TCK 158, deepfake duzenlemeleri)
 * Riza almadan kullanmayin.
 *
 *   node src/voice-clone.ts --sample ornek.wav --text "Merhaba dunya"
 *   node src/voice-clone.ts --sample esim.wav --model gemini-3.8-flash-tts
 */
import { GoogleGenAI } from '@google/genai';
import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { requireApiKey } from './env.ts';
import { extractPcmForClone, humanBytes, pcmDuration, toPlayableAudio } from './wav.ts';

function arg(name: string, fallback: string): string {
  const i = process.argv.indexOf(`--${name}`);
  return i !== -1 && process.argv[i + 1] ? process.argv[i + 1] : fallback;
}

const SAMPLE_PATH = resolve(arg('sample', 'out/voices/gemini-3.8-flash-tts/Fola.wav'));
const MODEL = arg('model', 'gemini-3.8-flash-tts');
const TEXT = arg('text', 'Merhaba, bu ses klonlama denemesidir.');
const OUT = resolve(arg('out', `out/cloned_${Date.now()}.wav`));
// Dusuk sicaklik klonun perdesini tutarli yapar; varsayilanda ayni ornek
// bir denemede 114 Hz, digerinde 213 Hz uretebiliyordu.
const TEMPERATURE = process.argv.includes('--temperature') ? Number(arg('temperature', '1')) : undefined;

if (!existsSync(SAMPLE_PATH)) {
  console.error(`[hata] Ses ornegi bulunamadi: ${SAMPLE_PATH}`);
  console.error('       Once bir ses uretin: node src/tts-test.ts');
  process.exit(1);
}

const sampleBytes = readFileSync(SAMPLE_PATH);
const { pcm, options } = extractPcmForClone(sampleBytes);

console.log('\n=== Ses Klonlama Denemesi ===');
console.log(`  ornek dosya : ${SAMPLE_PATH}`);
console.log(`  dosya boyut : ${humanBytes(sampleBytes.byteLength)}  (WAV basligi atildi -> ${humanBytes(pcm.byteLength)} PCM)`);
console.log(`  ornek format: ${options.numChannels} kanal, ${options.sampleRate} Hz, ${options.bitsPerSample} bit`);
console.log(`  ornek sure  : ${pcmDuration(pcm.byteLength, options).toFixed(2)} sn`);
console.log(`  model       : ${MODEL}`);
console.log('');

// API 24 kHz / 16-bit / mono bekliyor - uyumsuzsa uyaralim
if (options.sampleRate !== 24000 || options.bitsPerSample !== 16) {
  console.log(`  [UYARI] API 24000 Hz / 16-bit bekler. Ornek ${options.sampleRate} Hz / ${options.bitsPerSample} bit.`);
  console.log('          Klonlama reddedilebilir veya ses bozuk cikabilir.\n');
}

const ai = new GoogleGenAI({ apiKey: requireApiKey() });

try {
  const res = await ai.models.generateContent({
    model: MODEL,
    config: {
      ...(TEMPERATURE !== undefined ? { temperature: TEMPERATURE } : {}),
      responseModalities: ['audio'],
      speechConfig: {
        voiceConfig: {
          replicatedVoiceConfig: {
            mimeType: 'audio/wav',
            voiceSampleAudio: pcm.toString('base64'),
          },
        },
      },
    },
    contents: [{ role: 'user', parts: [{ text: TEXT }] }],
  });

  const inline = res.candidates?.[0]?.content?.parts?.find((p) => p.inlineData)?.inlineData;
  if (!inline?.data) {
    console.log('[SONUC] Ses verisi donmedi.');
    console.log(JSON.stringify(res.candidates?.[0]?.content, null, 2).slice(0, 800));
    process.exit(2);
  }

  const payload = Buffer.from(inline.data, 'base64');
  const result = toPlayableAudio(payload, inline.mimeType || '');

  mkdirSync(dirname(OUT), { recursive: true });
  const finalPath = OUT.replace(/\.[^./\\]+$/, '') + '.' + result.extension;
  writeFileSync(finalPath, result.buffer);

  console.log('[SONUC] Istek KABUL EDILDI');
  console.log(`  donen mime   : ${inline.mimeType}`);
  console.log(`  islem        : ${result.action === 'wrapped' ? 'ham PCM -> WAV sarmalandi' : 'tam WAV, oldugu gibi'}`);
  console.log(`  cikti        : ${finalPath}`);
  console.log(`  sure         : ${pcmDuration(result.buffer.byteLength - 44, result.options).toFixed(2)} sn`);
  console.log(`  dinle        : open "${finalPath}"`);
  console.log('\n  DIKKAT: Istegin kabul edilmesi sesin GERCEKTEN taklit edildigi anlamina gelmez.');
  console.log('  Nesnel dogrulama icin: node src/clone-proof.ts && python3 tools/analyze-voices.py');
} catch (err) {
  const msg = err instanceof Error ? err.message : String(err);
  console.log('[SONUC] KLONLAMA BASARISIZ');
  console.log(`  ${msg}`);
  if (/"code":(400|403|404)/.test(msg)) {
    console.log('\n  Muhtemel nedenler:');
    console.log('   - Bu ozellik API anahtarinizda/katmaninizda acik degil');
    console.log('   - Bu model ses klonlamayi desteklemiyor');
    console.log('   - Riza (consent) dogrulamasi gerekiyor');
  }
  process.exit(1);
}
