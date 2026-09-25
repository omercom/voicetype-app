/**
 * Adim 1: Hesapta hangi modeller var, hangileri TTS?
 *
 * Kullanim:
 *   node src/list-models.ts            # TTS olanlari ozetler
 *   node src/list-models.ts --all      # tum modelleri listeler
 *   node src/list-models.ts --grep tts # isim filtresi
 */
import { GoogleGenAI } from '@google/genai';
import { requireApiKey } from './env.ts';

const args = process.argv.slice(2);
const showAll = args.includes('--all');
const grepIdx = args.indexOf('--grep');
const grep = grepIdx !== -1 ? (args[grepIdx + 1] || '').toLowerCase() : null;

const ai = new GoogleGenAI({ apiKey: requireApiKey() });

const models = [];
for await (const m of await ai.models.list()) {
  models.push(m);
}

const rows = models.map((m) => ({
  name: (m.name || '').replace(/^models\//, ''),
  displayName: m.displayName || '',
  methods: m.supportedActions || [],
  description: (m.description || '').slice(0, 90),
}));

const ttsRows = rows.filter(
  (r) => r.name.toLowerCase().includes('tts') || r.displayName.toLowerCase().includes('tts') ||
    /text-?to-?speech/i.test(r.description),
);

console.log(`\n=== Toplam ${rows.length} model ===\n`);
console.log(`--- TTS ile ilgili ${ttsRows.length} model ---`);
for (const r of ttsRows) {
  console.log(`  ${r.name}`);
  console.log(`     display : ${r.displayName}`);
  console.log(`     methods : ${r.methods.join(', ') || '(yok)'}`);
}

if (grep) {
  const hits = rows.filter((r) => r.name.toLowerCase().includes(grep) || r.displayName.toLowerCase().includes(grep));
  console.log(`\n--- "${grep}" iceren ${hits.length} model ---`);
  for (const r of hits) console.log(`  ${r.name}  [${r.methods.join(', ')}]`);
}

if (showAll) {
  console.log(`\n--- Tum modeller ---`);
  for (const r of rows) console.log(`  ${r.name}  [${r.methods.join(', ')}]`);
}
