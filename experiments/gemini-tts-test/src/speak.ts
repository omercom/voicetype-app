/**
 * Klonlanmis sesle metin okutur. .env'deki TUM anahtarlari sirayla dener:
 * gunluk limiti dolan anahtardan sonrakine gecer. Her anahtarin projesinde
 * klon ses yoksa referans + onay kayitlarindan otomatik olusturur.
 *
 *   node src/speak.ts --text "Merhaba, bu benim sesim." --play
 *   node src/speak.ts --text-file metin.txt --out out/okuma.wav
 *   node src/speak.ts --model gemini-3.8-flash-tts --text "..."
 *   node src/speak.ts --voice voice_xxx --text "..."        # tek anahtarla belirli ses
 *
 * Secenekler: --name Omer  --source out/myvoice_v3_clean.wav  --consent out/consent_clean.wav
 *             --no-create (projede ses yoksa olusturma, sonraki anahtara gec)
 */
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { execFileSync } from 'node:child_process';
import { apiKeys, maskKey } from './env.ts';
import { QuotaError, createVoice, findVoice, forgetVoice, synthesize } from './voices-lib.ts';
import { toPlayableAudio } from './wav.ts';

function arg(name: string, fallback: string): string {
  const i = process.argv.indexOf(`--${name}`);
  return i !== -1 && process.argv[i + 1] ? process.argv[i + 1] : fallback;
}

const MODEL = arg('model', 'gemini-3.8-flash-lite-tts');
const NAME = arg('name', 'Omer');
const SOURCE = arg('source', 'out/myvoice_v3_clean.wav');
const CONSENT = arg('consent', 'out/consent_clean.wav');
const FIXED_VOICE = arg('voice', '');
const AUTO_CREATE = !process.argv.includes('--no-create');
const TEXT_FILE = arg('text-file', '');
const TEXT = TEXT_FILE ? readFileSync(resolve(TEXT_FILE), 'utf8') : arg('text', 'Merhaba, bu benim klonlanmış sesimle üretilmiş bir denemedir.');
const OUT = resolve(arg('out', `out/speak_${Date.now()}.wav`));

const keys = apiKeys();
console.log(`[tts] ${MODEL} · ${keys.length} anahtar · ses: ${FIXED_VOICE || NAME}`);

for (const key of keys) {
  const started = Date.now();
  try {
    let voice = FIXED_VOICE || (await findVoice(key, NAME));
    if (!voice) {
      if (!AUTO_CREATE) { console.log(`  ${maskKey(key)}: projede "${NAME}" sesi yok, geciliyor`); continue; }
      console.log(`  ${maskKey(key)}: projede ses yok, olusturuluyor...`);
      voice = await createVoice(key, { source: SOURCE, consent: CONSENT, name: NAME });
    }

    let audio;
    try {
      audio = await synthesize(key, MODEL, voice, TEXT);
    } catch (err) {
      // Ses silinmis/baska projeye ait olabilir: onbellegi temizle, bir kez yeniden bul.
      if (!FIXED_VOICE && err instanceof Error && /HTTP 404/.test(err.message)) {
        forgetVoice(key);
        voice = (await findVoice(key, NAME)) ?? (await createVoice(key, { source: SOURCE, consent: CONSENT, name: NAME }));
        audio = await synthesize(key, MODEL, voice, TEXT);
      } else throw err;
    }

    const playable = toPlayableAudio(audio.bytes, audio.mimeType);
    const path = OUT.replace(/\.[^./\\]+$/, '') + '.' + playable.extension;
    mkdirSync(dirname(path), { recursive: true });
    writeFileSync(path, playable.buffer);
    console.log(`[tamam] ${maskKey(key)} · ${voice} -> ${path}  (${Date.now() - started} ms)`);
    if (process.argv.includes('--play')) execFileSync('afplay', [path]);
    process.exit(0);
  } catch (err) {
    if (err instanceof QuotaError) { console.log(`  ${maskKey(key)}: gunluk limit dolu, sonraki anahtar`); continue; }
    console.log(`  ${maskKey(key)}: ${err instanceof Error ? err.message : err}`);
  }
}

console.error('[hata] Hicbir anahtarla uretilemedi (hepsinin limiti dolu olabilir).');
process.exit(1);
