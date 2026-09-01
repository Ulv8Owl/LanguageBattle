// 32 языка, которые поддерживает приложение: тег для провайдера ASR
// (bcp47For) и письменность для проверки «не тот язык»
// (definitelyNotLanguage).
//
// Почему именно 32 и именно эти — подробное обоснование в
// lib/core/all_languages.dart (стоимость контента, ликвидность очередей
// PvP, поддержка ASR). Здесь важно другое: набор и порядок кодов ОБЯЗАНЫ
// совпадать с той таблицей, и это проверяется тестом
// test/languages_test.dart, а не вниманием при правке.
//
// Наличие языка здесь НЕ значит, что на нём уже можно играть: для этого
// нужен ещё банк фраз и слов (assets/phrases, assets/vocab). Готовность
// контента считается по самому контенту — см. ContentLanguages в
// lib/data/content_languages.dart.

type Script =
  | "latin"
  | "cyrillic"
  | "greek"
  | "arabic"
  | "hebrew"
  | "devanagari"
  | "bengali"
  | "thai"
  | "han"
  | "kana"
  | "hangul";

interface LanguageInfo {
  /** Тег для провайдеров ASR. */
  bcp47: string;
  /**
   * Письменности, в которых распознаватель ВЫДАЁТ текст на этом языке —
   * не «в которых язык бывает записан». Для японского это кана и
   * иероглифы, а не латиница: транслитерацию ASR не возвращает.
   */
  scripts: Script[];
}

const LANGUAGES: Record<string, LanguageInfo> = {
  // --- Эшелон A: топ-12 изучаемых в мире и крупнейшие рынки ---
  en: { bcp47: "en-US", scripts: ["latin"] },
  es: { bcp47: "es-ES", scripts: ["latin"] },
  zh: { bcp47: "zh-CN", scripts: ["han"] },
  hi: { bcp47: "hi-IN", scripts: ["devanagari"] },
  ar: { bcp47: "ar-SA", scripts: ["arabic"] },
  pt: { bcp47: "pt-PT", scripts: ["latin"] },
  ru: { bcp47: "ru-RU", scripts: ["cyrillic"] },
  fr: { bcp47: "fr-FR", scripts: ["latin"] },
  de: { bcp47: "de-DE", scripts: ["latin"] },
  ja: { bcp47: "ja-JP", scripts: ["kana", "han"] },
  ko: { bcp47: "ko-KR", scripts: ["hangul"] },
  it: { bcp47: "it-IT", scripts: ["latin"] },

  // --- Эшелон B: большие базы носителей и растущие мобильные рынки ---
  id: { bcp47: "id-ID", scripts: ["latin"] },
  tr: { bcp47: "tr-TR", scripts: ["latin"] },
  vi: { bcp47: "vi-VN", scripts: ["latin"] },
  pl: { bcp47: "pl-PL", scripts: ["latin"] },
  nl: { bcp47: "nl-NL", scripts: ["latin"] },
  th: { bcp47: "th-TH", scripts: ["thai"] },
  uk: { bcp47: "uk-UA", scripts: ["cyrillic"] },
  fa: { bcp47: "fa-IR", scripts: ["arabic"] },
  bn: { bcp47: "bn-BD", scripts: ["bengali"] },
  ur: { bcp47: "ur-PK", scripts: ["arabic"] },

  // --- Эшелон C: остальная Европа и Филиппины ---
  sv: { bcp47: "sv-SE", scripts: ["latin"] },
  no: { bcp47: "nb-NO", scripts: ["latin"] },
  da: { bcp47: "da-DK", scripts: ["latin"] },
  fi: { bcp47: "fi-FI", scripts: ["latin"] },
  cs: { bcp47: "cs-CZ", scripts: ["latin"] },
  el: { bcp47: "el-GR", scripts: ["greek"] },
  he: { bcp47: "he-IL", scripts: ["hebrew"] },
  ro: { bcp47: "ro-RO", scripts: ["latin"] },
  hu: { bcp47: "hu-HU", scripts: ["latin"] },
  tl: { bcp47: "tl-PH", scripts: ["latin"] },
};

export function bcp47For(languageCode: string): string {
  return LANGUAGES[languageCode]?.bcp47 ?? "en-US";
}

/** Обратно: 'en-US' (или просто 'EN') -> 'en'. Регистр провайдеры не гарантируют. */
export function languageFromTag(tag: string | null | undefined): string | null {
  if (typeof tag !== "string" || tag.length === 0) return null;
  const base = tag.split(/[-_]/)[0].toLowerCase();
  return base in LANGUAGES ? base : null;
}

/** Известен ли этот код языка приложению вообще (для фильтрации альтернатив). */
export function isKnownLanguage(languageCode: string): boolean {
  return languageCode in LANGUAGES;
}

// Диапазоны Unicode по письменностям. Проверяются только БУКВЫ: цифры,
// знаки препинания и пробелы одинаковы почти везде и о языке не говорят
// ничего.
const SCRIPT_PATTERNS: [Script, RegExp][] = [
  // Латиница с расширениями: диакритика европейских языков (À-ɏ) и
  // вьетнамская (Latin Extended Additional).
  ["latin", /[A-Za-zÀ-ɏḀ-ỿ]/],
  ["cyrillic", /[Ѐ-ԯ]/],
  ["greek", /[Ͱ-Ͽἀ-῿]/],
  ["arabic", /[؀-ۿݐ-ݿﭐ-﷿ﹰ-﻿]/],
  ["hebrew", /[֐-׿]/],
  ["devanagari", /[ऀ-ॿ]/],
  ["bengali", /[ঀ-৿]/],
  ["thai", /[฀-๿]/],
  // Кана отдельно от иероглифов: текст с каной — точно японский, а текст
  // из одних иероглифов японским быть может, а может и не быть.
  ["kana", /[぀-ヿ]/],
  ["hangul", /[가-힯ᄀ-ᇿ㄰-㆏]/],
  ["han", /[㐀-䶿一-鿿豈-﫿]/],
];

function scriptsIn(text: string): Script[] {
  return SCRIPT_PATTERNS.filter(([, re]) => re.test(text)).map(([script]) => script);
}

/**
 * Точно ли этот текст НЕ на языке [target].
 *
 * Отвечает только «нет» и «не знаю»: определять, что за язык на самом деле,
 * здесь никто не пытается — это работа распознавателя, и он её уже сделал
 * (см. detectedLanguage в types.ts). Функция нужна на случай, когда
 * провайдер язык не назвал.
 *
 * Правило одно и работает для любой письменности: если НИ ОДНА из
 * встретившихся в тексте письменностей не используется в целевом языке —
 * говорили не на нём. Кириллица там, где ждали английский, — не догадка.
 * Иероглифы там, где ждали арабский, — тоже.
 *
 * Формулировка «ни одна» выбрана вместо «преобладает» намеренно: ответ с
 * вкраплением латиницы («Я говорю OK») остаётся неопределённым, и функция
 * молчит вместо того, чтобы обвинить игрока. Языки одной письменности
 * (английский и испанский, хинди и маратхи) она не различает — и не
 * должна: это работа провайдера, который сообщает язык сам.
 */
export function definitelyNotLanguage(text: string, target: string): boolean {
  const allowed = LANGUAGES[target]?.scripts;
  if (!allowed || allowed.length === 0) return false;
  const present = scriptsIn(text);
  if (present.length === 0) return false;
  return !present.some((script) => allowed.includes(script));
}
