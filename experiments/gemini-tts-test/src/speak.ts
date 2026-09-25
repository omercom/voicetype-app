/**
 * create-voice.ts ile olusturulan klon sesle metin okutur.
 *
 *   node src/speak.ts --text "Merhaba, bu benim sesim."
 *   node src/speak.ts --text-file metin.txt --out out/okuma.wav
 *   node src/speak.ts --voice voice_xxx --model gemini-3.8-flash-tts --play
 *
 * Ses kimligi verilmezse out/voice-id.txt dosyasindan okunur.
 */
import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { execFileSync } from 'node:child_process';
import { requireApiKey } from './env.ts';
import { toPlayableAudio } from './wav.ts';

function arg(name: string, fallback: string): string {
  const i = process.argv.indexOf(`--${name}`);
  return i !== -1 && process.argv[i + 1] ? process.argv[i + 1] : fallback;
}

const ID_FILE = resolve('out/voice-id.txt');
const VOICE = arg('voice', existsSync(ID_FILE) ? readFileSync(ID_FILE, 'utf8').trim() : '');
const MODEL = arg('model', 'gemini-3.8-flash-lite-tts');
const TEXT_FILE = arg('text-file', '');
const TEXT = TEXT_FILE ? readFileSync(resolve(TEXT_FILE), 'utf8') : arg('text', 'Merhaba, bu benim klonlanmış sesimle üretilmiş bir denemedir.');
const OUT = resolve(arg('out', `out/speak_${Date.now()}.wav`));

if (!VOICE) {
  console.error('[hata] Ses kimligi yok. Once: node src/create-voice.ts');
  process.exit(1);
}

const key = requireApiKey();
const started = Date.now();
const res = await fetch(`https://generativelanguage.googleapis.com/v1beta/models/${MODEL}:generateContent`, {
  method: 'POST',
  headers: { 'x-goog-api-key': key, 'Content-Type': 'application/json' },
  body: JSON.stringify({
    contents: [{ role: 'user', parts: [{ text: TEXT }] }],
    generationConfig: {
      responseModalities: ['AUDIO'],
      speechConfig: { voiceConfig: { voice: VOICE } },
    },
  }),
});
const body = await res.text();
if (!res.ok) {
  console.error(`[hata] HTTP ${res.status}\n${body.slice(0, 1200)}`);
  process.exit(1);
}

const json = JSON.parse(body);
const inline = json.candidates?.[0]?.content?.parts?.find((p: any) => p.inlineData)?.inlineData;
if (!inline?.data) {
  console.error('[hata] Yanitta ses yok:', body.slice(0, 600));
  process.exit(2);
}

const audio = toPlayableAudio(Buffer.from(inline.data, 'base64'), inline.mimeType ?? '');
const path = OUT.replace(/\.[^./\\]+$/, '') + '.' + audio.extension;
mkdirSync(dirname(path), { recursive: true });
writeFileSync(path, audio.buffer);
console.log(`[tamam] ${MODEL} + ${VOICE} -> ${path}  (${Date.now() - started} ms)`);

if (process.argv.includes('--play')) execFileSync('afplay', [path]);
