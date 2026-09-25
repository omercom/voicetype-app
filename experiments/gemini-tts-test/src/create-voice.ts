/**
 * Resmi Voices API ile kendi sesinden kalici bir klon sesi olusturur.
 *
 *   node src/create-voice.ts --source out/myvoice_v3_clean.wav --consent out/consent_clean.wav
 *   node src/create-voice.ts ... --model gemini-3.8-flash-lite-tts --name "Omer" --no-store
 *
 * Gerekenler (resmi dokuman):
 *   - source : ayni kisinin 10-30 sn temiz, dogal konusmasi (24 kHz mono 16-bit WAV)
 *   - consent: ayni kisi, ayni ortamda, onay cumlesini kelimesi kelimesine okur:
 *     "Bu sesin sahibi benim ve Google'in sentetik ses modeli olusturmak icin bu sesi
 *      kullanmasina izin veriyorum."
 *
 * Donen ses kimligi out/voice-id.txt dosyasina yazilir; speak.ts bunu kullanir.
 * store=true -> voice_... (1 yil), --no-store -> voicekey_... (7 gun).
 */
import { readFileSync, writeFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { requireApiKey } from './env.ts';

function arg(name: string, fallback: string): string {
  const i = process.argv.indexOf(`--${name}`);
  return i !== -1 && process.argv[i + 1] ? process.argv[i + 1] : fallback;
}

const SOURCE = resolve(arg('source', 'out/myvoice_v3_clean.wav'));
const CONSENT = resolve(arg('consent', 'out/consent_clean.wav'));
// Bos birakilirsa API varsayilan ses olusturma modelini kullanir; olusan ses
// Flash Lite dahil tum TTS modelleriyle konusturulabilir. Lite burada kabul edilmez.
const MODEL = arg('model', '');
const NAME = arg('name', 'Benim sesim');
// Onay cumlesinin hangi dilde okundugunu belirler; verilmezse sunucu
// Ingilizce cumleyi bekleyip Turkce onayi "eslesmedi" diye reddediyor.
const LANGUAGE = arg('language', 'tr-TR');
const STORE = !process.argv.includes('--no-store');
const ID_FILE = resolve(arg('id-file', 'out/voice-id.txt'));

const b64 = (path: string) => readFileSync(path).toString('base64');

const body = {
  store: STORE,
  voice: {
    ...(MODEL ? { model: MODEL } : {}),
    type: 'replicated',
    display_name: NAME,
    language_code: LANGUAGE,
    replicated: {
      source_audio: { mime_type: 'audio/wav', data: b64(SOURCE) },
      consent_audio: { mime_type: 'audio/wav', data: b64(CONSENT) },
    },
  },
};

const key = requireApiKey();
console.log(`\n=== Ses olusturuluyor ===\n  model  : ${MODEL || '(varsayilan)'}\n  kaynak : ${SOURCE}\n  onay   : ${CONSENT}\n  store  : ${STORE}\n`);

const res = await fetch('https://generativelanguage.googleapis.com/v1beta/voices', {
  method: 'POST',
  headers: { 'x-goog-api-key': key, 'Content-Type': 'application/json' },
  body: JSON.stringify(body),
});
const text = await res.text();

if (!res.ok) {
  console.error(`[hata] HTTP ${res.status}\n${text.slice(0, 1500)}`);
  process.exit(1);
}

const json = JSON.parse(text);
// Yanit bazen dogrudan Voice, bazen { voice: Voice } seklinde olabilir.
const voice = json.voice ?? json;
const id: string | undefined = voice.id ?? voice.name ?? voice.voiceKey ?? voice.voice_key;
console.log('[yanit]', JSON.stringify({ ...voice, sampleAudio: undefined, sample_audio: undefined }, null, 2).slice(0, 1200));

if (!id) {
  console.error('[hata] Yanitta ses kimligi bulunamadi.');
  process.exit(2);
}
writeFileSync(ID_FILE, `${id}\n`);
console.log(`\n[tamam] Ses kimligi: ${id}\n        Kaydedildi: ${ID_FILE}`);
