/**
 * Projedeki kayitli (store=true) klon ve tasarim seslerini listeler.
 *
 *   node src/list-voices.ts                      # sadece kendi seslerin (klon/tasarim)
 *   node src/list-voices.ts --all                # Google'in hazir sesleri dahil (~2000)
 *   node src/list-voices.ts --all --lang tr-TR   # sadece Turkce sesler
 *   node src/list-voices.ts --delete voice_xxx     # bir sesi kalici olarak siler
 */
import { requireApiKey } from './env.ts';

const BASE = 'https://generativelanguage.googleapis.com/v1beta/voices';
const key = requireApiKey();
const headers = { 'x-goog-api-key': key };

const del = process.argv.indexOf('--delete');
if (del !== -1 && process.argv[del + 1]) {
  const id = process.argv[del + 1];
  const res = await fetch(`${BASE}/${id}`, { method: 'DELETE', headers });
  console.log(res.ok ? `[silindi] ${id}` : `[hata] HTTP ${res.status} ${await res.text()}`);
  process.exit(res.ok ? 0 : 1);
}

const voices: any[] = [];
let pageToken = '';
do {
  const res = await fetch(`${BASE}?pageSize=50${pageToken ? `&pageToken=${pageToken}` : ''}`, { headers });
  const text = await res.text();
  if (!res.ok) {
    console.error(`[hata] HTTP ${res.status}\n${text.slice(0, 800)}`);
    process.exit(1);
  }
  const json = JSON.parse(text);
  voices.push(...(json.voices ?? []));
  pageToken = json.nextPageToken ?? json.next_page_token ?? '';
} while (pageToken);

const showAll = process.argv.includes('--all');
const langIdx = process.argv.indexOf('--lang');
const langFilter = langIdx !== -1 ? process.argv[langIdx + 1] : '';
const shown = voices
  .filter((v) => showAll || (v.type ?? '') !== 'prebuilt')
  .filter((v) => !langFilter || (v.languageCode ?? v.language_code) === langFilter);
voices.length = 0;
voices.push(...shown);

if (voices.length === 0) {
  console.log('\nKayitli ses yok.');
  process.exit(0);
}

console.log(`\n=== Kayitli sesler (${voices.length}) ===`);
for (const v of voices) {
  const id = v.id ?? v.name;
  const name = v.displayName ?? v.display_name ?? '';
  const type = v.type ?? '';
  const lang = v.languageCode ?? v.language_code ?? '';
  const expires = v.expireTime ?? v.expire_time ?? '';
  console.log(`  ${id}  ${type.padEnd(10)}  ${name}  ${lang}  bitis: ${expires}`);
}
console.log('\nKullanmak icin: node src/speak.ts --voice <id> --text "..." --play');
