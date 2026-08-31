// Разбор WAV и base64 — общие мелочи, которыми пользуются несколько
// провайдеров (сейчас только Google, но deepgram грузит аудио как есть, а
// следующий провайдер может снова прийти с чем-то в духе Google).

/**
 * Разбор WAV-контейнера, который пишет клиент (record, AudioEncoder.wav).
 *
 * Google STT принимает и файл целиком (тогда encoding/sampleRateHertz
 * определяются по заголовку), но полагаться на автоопределение незачем:
 * заголовок разбирается тривиально, а взамен мы точно знаем реальную
 * частоту дискретизации устройства — она может отличаться от запрошенной,
 * если железо не умеет 16 кГц, и тогда автоопределение спасёт, а жёстко
 * зашитые 16000 испортили бы распознавание.
 */
export interface WavData {
  pcm: Uint8Array;
  sampleRate: number;
  channels: number;
  bitsPerSample: number;
}

export function parseWav(bytes: Uint8Array): WavData | null {
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  const tag = (offset: number) =>
    String.fromCharCode(bytes[offset], bytes[offset + 1], bytes[offset + 2], bytes[offset + 3]);

  if (bytes.byteLength < 12 || tag(0) !== "RIFF" || tag(8) !== "WAVE") return null;

  let sampleRate = 0;
  let channels = 0;
  let bitsPerSample = 0;
  let pcm: Uint8Array | null = null;

  // Чанки идут подряд: 4 байта имени, 4 байта длины, дальше данные с
  // выравниванием до чётного размера. Между fmt и data может лежать что
  // угодно (LIST/fact) — поэтому идём циклом, а не по фиксированным
  // смещениям "как обычно бывает".
  let offset = 12;
  while (offset + 8 <= bytes.byteLength) {
    const id = tag(offset);
    const size = view.getUint32(offset + 4, true);
    const body = offset + 8;

    if (id === "fmt " && body + 16 <= bytes.byteLength) {
      channels = view.getUint16(body + 2, true);
      sampleRate = view.getUint32(body + 4, true);
      bitsPerSample = view.getUint16(body + 14, true);
    } else if (id === "data") {
      const end = Math.min(body + size, bytes.byteLength);
      pcm = bytes.subarray(body, end);
      break;
    }

    offset = body + size + (size % 2);
  }

  if (!pcm || sampleRate === 0 || channels === 0) return null;
  return { pcm, sampleRate, channels, bitsPerSample };
}

/** base64 без промежуточной строки на каждый байт — записи бывают под мегабайт. */
export function toBase64(bytes: Uint8Array): string {
  let binary = "";
  const chunk = 0x8000;
  for (let i = 0; i < bytes.byteLength; i += chunk) {
    binary += String.fromCharCode(...bytes.subarray(i, i + chunk));
  }
  return btoa(binary);
}
