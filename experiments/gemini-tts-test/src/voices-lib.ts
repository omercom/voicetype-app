/**
 * Voices API yardimcilari: sesi bulma, olusturma, konusturma.
 * Kayitli sesler PROJEYE aittir; her anahtarin projesinde ses ayri olusturulur.
 * Anahtar -> ses kimligi eslemesi out/voices.json'da onbelleklenir.
 */
import { existsSync, readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { dirname, resolve } from 'node:path';

const API = 'https://generativelanguage.googleapis.com/v1beta';
const CACHE = resolve('out/voices.json');

export class QuotaError extends Error {}

const fingerprint = (key: string) => key.slice(-8);

function readCache(): Record<string, string> {
  try { return JSON.parse(readFileSync(CACHE, 'utf8')); } catch { return {}; }
}
function writeCache(cache: Record<string, string>) {
  mkdirSync(dirname(CACHE), { recursive: true });
  writeFileSync(CACHE, JSON.stringify(cache, null, 2));
}
export function forgetVoice(key: string) {
  const cache = readCache();
  delete cache[fingerprint(key)];
  writeCache(cache);
}

async function call(key: string, path: string, init: RequestInit = {}) {
  const res = await fetch(`${API}${path}`, {
    ...init,
    headers: { 'x-goog-api-key': key, 'Content-Type': 'application/json', ...(init.headers ?? {}) },
  });
  const text = await res.text();
  if (res.status === 429) throw new QuotaError(text.match(/limit: \d+[^"\\]*/)?.[0] ?? 'kota doldu');
  if (!res.ok) throw new Error(`HTTP ${res.status}: ${text.match(/"message": "([^"]{0,300})/)?.[1] ?? text.slice(0, 300)}`);
  return text ? JSON.parse(text) : {};
}

/** Projede bu isimle kayitli klon sesi bulur (onbellek -> liste). */
export async function findVoice(key: string, name: string): Promise<string | undefined> {
  const cached = readCache()[fingerprint(key)];
  if (cached) return cached;
  let pageToken = '';
  do {
    const json = await call(key, `/voices?pageSize=100${pageToken ? `&pageToken=${pageToken}` : ''}`);
    const hit = (json.voices ?? []).find((v: any) =>
      v.type === 'replicated' && (v.displayName ?? v.display_name) === name);
    if (hit) {
      const cache = readCache();
      cache[fingerprint(key)] = hit.id ?? hit.name;
      writeCache(cache);
      return cache[fingerprint(key)];
    }
    pageToken = json.nextPageToken ?? '';
  } while (pageToken);
  return undefined;
}

export async function createVoice(key: string, opts: {
  source: string; consent: string; name: string; language?: string; store?: boolean; model?: string;
}): Promise<string> {
  const b64 = (p: string) => readFileSync(resolve(p)).toString('base64');
  const json = await call(key, '/voices', {
    method: 'POST',
    body: JSON.stringify({
      store: opts.store ?? true,
      voice: {
        ...(opts.model ? { model: opts.model } : {}),
        type: 'replicated',
        display_name: opts.name,
        // Verilmezse sunucu Ingilizce onay cumlesini bekler ve Turkce onayi reddeder.
        language_code: opts.language ?? 'tr-TR',
        replicated: {
          source_audio: { mime_type: 'audio/wav', data: b64(opts.source) },
          consent_audio: { mime_type: 'audio/wav', data: b64(opts.consent) },
        },
      },
    }),
  });
  const voice = json.voice ?? json;
  const id: string = voice.id ?? voice.name ?? voice.key;
  if (!id) throw new Error('Yanitta ses kimligi yok');
  const cache = readCache();
  cache[fingerprint(key)] = id;
  writeCache(cache);
  return id;
}

/** Ham ses baytlari + mime tipi doner. */
export async function synthesize(key: string, model: string, voice: string, text: string) {
  const json = await call(key, `/models/${model}:generateContent`, {
    method: 'POST',
    body: JSON.stringify({
      contents: [{ role: 'user', parts: [{ text }] }],
      generationConfig: { responseModalities: ['AUDIO'], speechConfig: { voiceConfig: { voice } } },
    }),
  });
  const inline = json.candidates?.[0]?.content?.parts?.find((p: any) => p.inlineData)?.inlineData;
  if (!inline?.data) throw new Error('Yanitta ses yok');
  return { bytes: Buffer.from(inline.data, 'base64'), mimeType: inline.mimeType ?? '' };
}

export { existsSync };
