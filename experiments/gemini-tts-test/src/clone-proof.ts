/**
 * KONTROLLU KLONLAMA DOGRULAMASI
 *
 * Amac: "klonlama calisti" demek yetmez. Gercekten hedef sesi mi taklit
 * ediyor, yoksa sessizce varsayilan bir sese mi dusuyor?
 *
 * Yontem:
 *   A) prebuilt Fola  ile ayni metin
 *   B) prebuilt Zephyr ile ayni metin
 *   C) Zephyr ORNEGI ile replicated (klon) + ayni metin
 *
 * Beklenti: C'nin akustik parmak izi B'ye A'dan daha yakin olmali.
 * Eger C, A'ya daha yakinsa -> klonlama yok sayiliyor / varsayilana dusuyor demektir.
 */
import { GoogleGenAI } from '@google/genai';
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { requireApiKey } from './env.ts';
import { extractPcmForClone, isWav, toPlayableAudio } from './wav.ts';

function arg(name: string, fallback: string): string {
  const i = process.argv.indexOf(`--${name}`);
  return i !== -1 && process.argv[i + 1] ? process.argv[i + 1] : fallback;
}

const TEXT = 'Bugun hava cok guzel ve ben bir klonlama denemesi yapiyorum.';
const MODEL = arg('model', 'gemini-3.8-flash-tts');
const OUT_DIR = arg('out-dir', 'out/clone-proof');

const ai = new GoogleGenAI({ apiKey: requireApiKey() });
mkdirSync(OUT_DIR, { recursive: true });

async function gen(label: string, voiceConfig: object): Promise<string> {
  const res = await ai.models.generateContent({
    model: MODEL,
    config: { responseModalities: ['audio'], speechConfig: { voiceConfig } },
    contents: [{ role: 'user', parts: [{ text: TEXT }] }],
  });
  const inline = res.candidates?.[0]?.content?.parts?.find((p) => p.inlineData)?.inlineData;
  if (!inline?.data) throw new Error(`${label}: ses verisi yok`);

  const payload = Buffer.from(inline.data, 'base64');
  // Bicim karari baytlara bakilarak verilir - cift baslik olusmaz
  const result = toPlayableAudio(payload, inline.mimeType || '');

  const file = join(OUT_DIR, `${label}.wav`);
  writeFileSync(file, result.buffer);
  console.log(
    `  [uretildi] ${label.padEnd(22)} mime=${(inline.mimeType || '?').padEnd(9)} ` +
      `icerik=${isWav(payload) ? 'WAV' : 'PCM'} islem=${result.action.padEnd(14)} ` +
      `${(result.buffer.byteLength / 1024).toFixed(0)} KB`,
  );
  return file;
}

const prebuilt = (name: string) => ({ prebuiltVoiceConfig: { voiceName: name } });

console.log('\n=== Kontrollu klonlama dogrulamasi ===');
console.log(`  metin : "${TEXT}"`);
console.log(`  model : ${MODEL}\n`);

await gen('A_prebuilt_Fola', prebuilt('Fola'));
await gen('B_prebuilt_Zephyr', prebuilt('Zephyr'));

// Simetrik test: her iki kaynaktan da klon uret
for (const [srcName, label] of [
  ['Zephyr', 'C_clone_from_Zephyr'],
  ['Fola', 'D_clone_from_Fola'],
] as const) {
  const srcPath = `out/voices/gemini-3.8-flash-tts/${srcName}.wav`;
  const sampleBytes = readFileSync(srcPath);
  const { pcm, options } = extractPcmForClone(sampleBytes);
  console.log(
    `  [ornek]    ${srcName.padEnd(22)} ${(pcm.byteLength / 1024).toFixed(0)} KB PCM ` +
      `(${options.sampleRate} Hz, ${options.bitsPerSample} bit)`,
  );
  await gen(label, {
    replicatedVoiceConfig: { mimeType: 'audio/wav', voiceSampleAudio: pcm.toString('base64') },
  });
}

console.log(`\n  Cikti klasoru: ${OUT_DIR}/`);
console.log('\n  BEKLENEN (klonlama calisiyorsa):');
console.log('    C_clone_from_Zephyr  ->  B_prebuilt_Zephyr e yakin');
console.log('    D_clone_from_Fola    ->  A_prebuilt_Fola ya yakin');
console.log('\n  Analiz: python3 tools/compare-voices.py ' + OUT_DIR);
