/**
 * Kucuk yardimci: repo kokundeki .env dosyasini yukler.
 * Ayri bir dotenv bagimliligi eklememek icin elle parse ediyoruz.
 */
import { existsSync, readFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

export const here = dirname(fileURLToPath(import.meta.url));

/** Bu dosyadan yukari dogru .git klasoru arayarak repo kokunu bulur. */
export function findRepoRoot(start: string = here): string {
  let dir = resolve(start);
  while (true) {
    if (existsSync(join(dir, '.git'))) return dir;
    const parent = resolve(dir, '..');
    if (parent === dir) return resolve(start);
    dir = parent;
  }
}

/** Repo kokundeki .env dosyasini process.env'e yukler. */
export function loadEnv(start: string = here): { root: string; loaded: string[] } {
  const root = findRepoRoot(start);
  const envPath = join(root, '.env');
  const loaded: string[] = [];

  if (!existsSync(envPath)) return { root, loaded };

  for (const rawLine of readFileSync(envPath, 'utf8').split(/\r?\n/)) {
    const line = rawLine.trim();
    if (!line || line.startsWith('#')) continue;

    const eq = line.indexOf('=');
    if (eq === -1) continue;

    const key = line.slice(0, eq).trim();
    const value = line
      .slice(eq + 1)
      .trim()
      .replace(/^["']|["']$/g, '');

    // Shell'de zaten tanimliysa ona dokunma
    if (value && !process.env[key]) {
      process.env[key] = value;
      loaded.push(key);
    }
  }

  return { root, loaded };
}

export function requireApiKey(): string {
  const { root, loaded } = loadEnv();
  const key = process.env.GEMINI_API_KEY || process.env.GOOGLE_API_KEY || '';
  if (!key) {
    console.error(`[hata] GEMINI_API_KEY bulunamadi.`);
    console.error(`       .env yolu beklenen konum: ${join(root, '.env')}`);
    console.error(`       veya shell'de: export GEMINI_API_KEY=...`);
    process.exit(1);
  }
  if (loaded.length) console.log(`[env] ${root}/.env -> yuklenen anahtarlar: ${loaded.join(', ')}`);
  console.log(`[env] kullanilan API key: ${key.slice(0, 6)}...${key.slice(-4)} (${key.length} karakter)`);
  return key;
}

/**
 * .env icindeki tum Gemini anahtarlari: GEMINI_API_KEYS (virgulle ayrilmis)
 * + GEMINI_API_KEY. Tekrarlar atilir, sira korunur. Limit anahtara degil
 * projeye baglidir; farkli projelerin anahtarlari ayri gunluk hak demektir.
 */
export function apiKeys(): string[] {
  loadEnv();
  const list = [
    ...(process.env.GEMINI_API_KEYS ?? '').split(','),
    process.env.GEMINI_API_KEY ?? '',
    process.env.GOOGLE_API_KEY ?? '',
  ].map((k) => k.trim()).filter(Boolean);
  const keys = [...new Set(list)];
  if (keys.length === 0) {
    console.error('[hata] Hic Gemini anahtari yok (.env: GEMINI_API_KEYS veya GEMINI_API_KEY).');
    process.exit(1);
  }
  return keys;
}

/** Anahtari loglarda gizler. */
export const maskKey = (key: string) => `…${key.slice(-4)}`;
