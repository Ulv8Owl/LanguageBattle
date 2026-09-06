/**
 * Коды языков и их теги BCP-47.
 *
 * Раньше это лежало в _shared/asr/languages.ts вместе с определением
 * письменности и защитой «ответил не на том языке». Распознавание удалено
 * целиком — речь разбирает мультимодальная модель, — и от всего файла
 * пережило только то, что нужно СИНТЕЗУ: назвать голосу язык.
 */
interface LanguageInfo {
  /** Тег BCP-47 для провайдеров: en -> en-US, ru -> ru-RU. */
  bcp47: string;
}

const LANGUAGES: Record<string, LanguageInfo> = {
  // --- Эшелон A: топ-12 изучаемых в мире и крупнейшие рынки ---
  en: { bcp47: "en-US" },
  es: { bcp47: "es-ES" },
  zh: { bcp47: "zh-CN" },
  hi: { bcp47: "hi-IN" },
  ar: { bcp47: "ar-SA" },
  pt: { bcp47: "pt-PT" },
  ru: { bcp47: "ru-RU" },
  fr: { bcp47: "fr-FR" },
  de: { bcp47: "de-DE" },
  ja: { bcp47: "ja-JP" },
  ko: { bcp47: "ko-KR" },
  it: { bcp47: "it-IT" },

  // --- Эшелон B: большие базы носителей и растущие мобильные рынки ---
  id: { bcp47: "id-ID" },
  tr: { bcp47: "tr-TR" },
  vi: { bcp47: "vi-VN" },
  pl: { bcp47: "pl-PL" },
  nl: { bcp47: "nl-NL" },
  th: { bcp47: "th-TH" },
  uk: { bcp47: "uk-UA" },
  fa: { bcp47: "fa-IR" },
  bn: { bcp47: "bn-BD" },
  ur: { bcp47: "ur-PK" },

  // --- Эшелон C: остальная Европа и Филиппины ---
  sv: { bcp47: "sv-SE" },
  no: { bcp47: "nb-NO" },
  da: { bcp47: "da-DK" },
  fi: { bcp47: "fi-FI" },
  cs: { bcp47: "cs-CZ" },
  el: { bcp47: "el-GR" },
  he: { bcp47: "he-IL" },
  ro: { bcp47: "ro-RO" },
  hu: { bcp47: "hu-HU" },
  tl: { bcp47: "tl-PH" },
};

export function bcp47For(languageCode: string): string {
  return LANGUAGES[languageCode]?.bcp47 ?? "en-US";
}

/** Обратно: 'en-US' (или просто 'EN') -> 'en'. Регистр провайдеры не гарантируют. */
export function isKnownLanguage(languageCode: string): boolean {
  return languageCode in LANGUAGES;
}

// Диапазоны Unicode по письменностям. Проверяются только БУКВЫ: цифры,
// знаки препинания и пробелы одинаковы почти везде и о языке не говорят
// ничего.
