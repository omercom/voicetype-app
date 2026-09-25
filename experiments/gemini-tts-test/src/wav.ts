/**
 * Ses bicimi yardimcilari - TEK KAYNAK.
 *
 * Neden bu modul var: Gemini TTS, cagri tipine gore FARKLI konteyner donduruyor:
 *   - streaming  -> 'audio/l16; rate=24000; channels=1'  (basliksiz ham PCM)
 *   - non-stream -> 'audio/wav'                          (ZATEN TAM WAV)
 *
 * Onceki surumlerde kosulsuzca 44 baytlik WAV basligi ekleniyordu. non-stream
 * cagrilarinda bu, WAV'in icine WAV gomulmesine yol aciyordu:
 *   [uydurma baslik 44B] + [RIFF gercek baslik 44B] + [PCM]
 * Sonuc: basinda ~1 ms gurultu, sure yanlis raporlanir, dosya teknik olarak bozuk.
 *
 * Cozum: beyan edilen mimeType'a guvenmek yerine dosyanin MAGIC BYTES'ina bak.
 * 'RIFF' ile basliyorsa zaten WAV'dir, dokunmadan gecir.
 */
import { Buffer } from 'node:buffer';

export interface WavOptions {
  numChannels: number;
  sampleRate: number;
  bitsPerSample: number;
}

/** Varsayilanlar: Gemini TTS'in kullandigi format. */
export const DEFAULT_OPTIONS: WavOptions = { numChannels: 1, sampleRate: 24000, bitsPerSample: 16 };

/** 'audio/L16;rate=24000;channels=2' gibi bir mimeType'i ayristirir. */
export function parseMimeType(mimeType: string): WavOptions {
  const options: WavOptions = { ...DEFAULT_OPTIONS };
  if (!mimeType) return options;

  const [fileType, ...params] = mimeType.split(';').map((s) => s.trim());
  const format = fileType.split('/')[1] || '';

  // audio/L16 -> 16 bit, audio/L24 -> 24 bit
  const bits = /^L(\d+)$/.exec(format);
  if (bits) options.bitsPerSample = parseInt(bits[1], 10);

  for (const param of params) {
    const [key, value] = param.split('=').map((s) => s.trim());
    if (key === 'rate') options.sampleRate = parseInt(value, 10) || options.sampleRate;
    if (key === 'channels') options.numChannels = parseInt(value, 10) || options.numChannels;
  }
  return options;
}

/** Baytlari kucuk-endian tamsayiya cevirir. */
const u32 = (b: Buffer, o: number) => b.readUInt32LE(o);
const u16 = (b: Buffer, o: number) => b.readUInt16LE(o);

/** Buffer gercek bir RIFF/WAVE konteyneri mi? */
export function isWav(buf: Buffer): boolean {
  return buf.byteLength >= 12 && buf.toString('ascii', 0, 4) === 'RIFF' && buf.toString('ascii', 8, 12) === 'WAVE';
}

/**
 * Mevcut bir WAV dosyasinin gercek parametrelerini basligindan okur.
 * 'fmt ' chunk'ini tarar, 'data' chunk'inin konumunu ve uzunlugunu bulur.
 */
export function readWavInfo(buf: Buffer): WavOptions & { dataOffset: number; dataLength: number } {
  const info = { ...DEFAULT_OPTIONS, dataOffset: 44, dataLength: Math.max(0, buf.byteLength - 44) };
  if (!isWav(buf)) return info;

  // RIFF chunk'larini sirayla gez (fmt her zaman ilk olmayabilir)
  let pos = 12;
  while (pos + 8 <= buf.byteLength) {
    const id = buf.toString('ascii', pos, pos + 4);
    const size = u32(buf, pos + 4);
    const body = pos + 8;

    if (id === 'fmt ' && body + 16 <= buf.byteLength) {
      info.numChannels = u16(buf, body + 2);
      info.sampleRate = u32(buf, body + 4);
      info.bitsPerSample = u16(buf, body + 14);
    } else if (id === 'data') {
      // Bilinen bir tuzak: ChunkSize alani bazen yanlis (0 veya 0xFFFFFFFF).
      // Bu yuzden dosyada kalan gercek bayt sayisini ust sinir olarak kullaniyoruz.
      const available = buf.byteLength - body;
      info.dataOffset = body;
      info.dataLength = size > 0 && size <= available ? size : available;
      break;
    }

    // Chunk'lar cift sayi hizasinda; tek sayi boyutlarda 1 bayt dolgu var
    pos = body + size + (size % 2);
  }

  return info;
}

/** Duz PCM verisini WAV basligiyla sarar. */
export function buildWavHeader(dataLength: number, o: WavOptions): Buffer {
  const { numChannels: ch, sampleRate: rate, bitsPerSample: bits } = o;
  const header = Buffer.alloc(44);

  header.write('RIFF', 0); // ChunkID
  header.writeUInt32LE(36 + dataLength, 4); // ChunkSize
  header.write('WAVE', 8); // Format
  header.write('fmt ', 12); // Subchunk1ID
  header.writeUInt32LE(16, 16); // Subchunk1Size (PCM)
  header.writeUInt16LE(1, 20); // AudioFormat = 1 (PCM)
  header.writeUInt16LE(ch, 22);
  header.writeUInt32LE(rate, 24);
  header.writeUInt32LE((rate * ch * bits) / 8, 28); // ByteRate
  header.writeUInt16LE((ch * bits) / 8, 32); // BlockAlign
  header.writeUInt16LE(bits, 34);
  header.write('data', 36); // Subchunk2ID
  header.writeUInt32LE(dataLength, 40); // Subchunk2Size

  return header;
}

export interface PlayableAudio {
  buffer: Buffer;
  extension: string;
  options: WavOptions;
  /** Ne yapildi: 'gecirildi' | 'sarmalandi' */
  action: 'passed-through' | 'wrapped';
}

/**
 * API'den donen ses yukunu calinabilir bir dosyaya cevirir.
 * Karar, mimeType'a DEGIL, baytlarin kendisine bakilarak verilir.
 */
export function toPlayableAudio(payload: Buffer, mimeType: string): PlayableAudio {
  const mt = mimeType || '';

  // 1) Zaten tam bir WAV geldiyse dokunma - parametreleri basligindan oku
  if (isWav(payload)) {
    const info = readWavInfo(payload);
    return {
      buffer: payload,
      extension: 'wav',
      options: { numChannels: info.numChannels, sampleRate: info.sampleRate, bitsPerSample: info.bitsPerSample },
      action: 'passed-through',
    };
  }

  // 2) Zaten kodlanmis diger formatlar
  const otherExt = /audio\/(mpeg|mp3)/i.test(mt) ? 'mp3' : /audio\/ogg/i.test(mt) ? 'ogg' : null;
  if (otherExt) {
    return { buffer: payload, extension: otherExt, options: { ...DEFAULT_OPTIONS }, action: 'passed-through' };
  }

  // 3) Ham PCM (audio/l16, audio/pcm) -> basligi biz ekliyoruz
  const options = parseMimeType(mt);
  return {
    buffer: Buffer.concat([buildWavHeader(payload.byteLength, options), payload]),
    extension: 'wav',
    options,
    action: 'wrapped',
  };
}

/** PCM'in saniye cinsinden suresi. */
export function pcmDuration(bytes: number, o: WavOptions): number {
  const bytesPerSample = o.bitsPerSample / 8;
  return bytes / (o.sampleRate * o.numChannels * bytesPerSample);
}

/**
 * Bir ses ornegini klonlama API'si icin hazirlar.
 * API ham PCM bekliyor (24 kHz, 16-bit, LE), bu yuzden WAV basligini atar.
 */
export function extractPcmForClone(buf: Buffer): { pcm: Buffer; options: WavOptions } {
  if (isWav(buf)) {
    const info = readWavInfo(buf);
    return {
      pcm: buf.subarray(info.dataOffset, info.dataOffset + info.dataLength),
      options: { numChannels: info.numChannels, sampleRate: info.sampleRate, bitsPerSample: info.bitsPerSample },
    };
  }
  return { pcm: buf, options: { ...DEFAULT_OPTIONS } };
}

/** Insan okunabilir boyut. */
export function humanBytes(n: number): string {
  if (n < 1024) return `${n} B`;
  if (n < 1048576) return `${(n / 1024).toFixed(1)} KB`;
  return `${(n / 1048576).toFixed(2)} MB`;
}
