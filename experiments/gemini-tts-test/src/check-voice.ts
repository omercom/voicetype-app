/**
 * Ses adi kesfedici: bir ses adini hedef modelde deneyip gecerli olup olmadigini soyler.
 *
 *   node src/check-voice.ts Fola
 *   node src/check-voice.ts Fola gemini-2.5-flash-preview-tts
 *
 * Amac: hangi ses adlari hangi modellerde gecerli, tam listeyi API'den ogrenmek
 * kolay olmadigi icin hata mesajindaki ipuclarini da yazdirir.
 */
import { GoogleGenAI } from '@google/genai';
import { requireApiKey } from './env.ts';

const voice = process.argv[2] || 'Fola';
const model = process.argv[3] || 'gemini-3.8-flash-tts';

const ai = new GoogleGenAI({ apiKey: requireApiKey() });

try {
  const res = await ai.models.generateContent({
    model,
    config: {
      responseModalities: ['audio'],
      speechConfig: { voiceConfig: { prebuiltVoiceConfig: { voiceName: voice } } },
    },
    contents: [{ role: 'user', parts: [{ text: 'Test.' }] }],
  });
  const inline = res.candidates?.[0]?.content?.parts?.find((p) => p.inlineData)?.inlineData;
  console.log(`\n[SONUC] "${voice}" @ ${model} -> GECERLI`);
  console.log(`        ${inline ? `${(Buffer.from(inline.data || '', 'base64').byteLength / 1024).toFixed(1)} KB ses uretildi` : 'ses verisi donmedi'}`);
  console.log(`        mimeType: ${inline?.mimeType}`);
} catch (err) {
  const msg = err instanceof Error ? err.message : String(err);
  console.log(`\n[SONUC] "${voice}" @ ${model} -> GECERSIZ`);
  // Hata mesaji genelde desteklenen seslerin tam listesini icerir
  console.log(`        ${msg}`);
  const list = /\[([^\]]+)\]/.exec(msg);
  if (list) {
    const voices = list[1].split(',').map((v) => v.trim().replace(/^"|"$/g, ''));
    console.log(`\n        Bu model icin desteklenen ${voices.length} ses:`);
    for (let i = 0; i < voices.length; i += 6) {
      console.log(`          ${voices.slice(i, i + 6).join(', ')}`);
    }
  }
  process.exit(1);
}
