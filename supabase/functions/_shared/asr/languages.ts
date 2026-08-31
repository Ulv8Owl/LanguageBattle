// Языки, которые приложение УМЕЕТ ОПОЗНАТЬ — как родной язык игрока, для
// проверки «не тот язык» (definitelyNotLanguage) и для тега провайдера
// (bcp47For). Это НЕ список того, что можно ВЫБРАТЬ изучать — тот короче и
// живёт в контенте (assets/phrases, assets/vocab): язык учить нельзя, пока
// для него нет банка фраз, но опознать его как родной нужно уже сейчас.
//
// Порядок и набор кодов ДОЛЖНЫ совпадать с allLanguages в
// lib/core/all_languages.dart — там та же таблица нужна интерфейсу
// (выбор родного языка в Настройках). Изменения вносить в обоих местах.

type Script =
  | "latin"
  | "cyrillic"
  | "greek"
  | "arabic"
  | "hebrew"
  | "armenian"
  | "georgian"
  | "devanagari"
  | "bengali"
  | "gurmukhi"
  | "gujarati"
  | "tamil"
  | "telugu"
  | "kannada"
  | "malayalam"
  | "sinhala"
  | "thai"
  | "lao"
  | "khmer"
  | "myanmar"
  | "tibetan"
  | "ethiopic"
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
  en: { bcp47: "en-US", scripts: ["latin"] },
  es: { bcp47: "es-ES", scripts: ["latin"] },
  ru: { bcp47: "ru-RU", scripts: ["cyrillic"] },
  zh: { bcp47: "zh-CN", scripts: ["han"] },
  de: { bcp47: "de-DE", scripts: ["latin"] },
  ko: { bcp47: "ko-KR", scripts: ["hangul"] },
  fr: { bcp47: "fr-FR", scripts: ["latin"] },
  ja: { bcp47: "ja-JP", scripts: ["kana", "han"] },
  pt: { bcp47: "pt-PT", scripts: ["latin"] },
  tr: { bcp47: "tr-TR", scripts: ["latin"] },
  pl: { bcp47: "pl-PL", scripts: ["latin"] },
  ca: { bcp47: "ca-ES", scripts: ["latin"] },
  nl: { bcp47: "nl-NL", scripts: ["latin"] },
  ar: { bcp47: "ar-SA", scripts: ["arabic"] },
  sv: { bcp47: "sv-SE", scripts: ["latin"] },
  it: { bcp47: "it-IT", scripts: ["latin"] },
  id: { bcp47: "id-ID", scripts: ["latin"] },
  hi: { bcp47: "hi-IN", scripts: ["devanagari"] },
  fi: { bcp47: "fi-FI", scripts: ["latin"] },
  vi: { bcp47: "vi-VN", scripts: ["latin"] },
  he: { bcp47: "he-IL", scripts: ["hebrew"] },
  uk: { bcp47: "uk-UA", scripts: ["cyrillic"] },
  el: { bcp47: "el-GR", scripts: ["greek"] },
  ms: { bcp47: "ms-MY", scripts: ["latin"] },
  cs: { bcp47: "cs-CZ", scripts: ["latin"] },
  ro: { bcp47: "ro-RO", scripts: ["latin"] },
  da: { bcp47: "da-DK", scripts: ["latin"] },
  hu: { bcp47: "hu-HU", scripts: ["latin"] },
  ta: { bcp47: "ta-IN", scripts: ["tamil"] },
  no: { bcp47: "nb-NO", scripts: ["latin"] },
  th: { bcp47: "th-TH", scripts: ["thai"] },
  ur: { bcp47: "ur-PK", scripts: ["arabic"] },
  hr: { bcp47: "hr-HR", scripts: ["latin"] },
  bg: { bcp47: "bg-BG", scripts: ["cyrillic"] },
  lt: { bcp47: "lt-LT", scripts: ["latin"] },
  la: { bcp47: "la", scripts: ["latin"] },
  mi: { bcp47: "mi-NZ", scripts: ["latin"] },
  ml: { bcp47: "ml-IN", scripts: ["malayalam"] },
  cy: { bcp47: "cy-GB", scripts: ["latin"] },
  sk: { bcp47: "sk-SK", scripts: ["latin"] },
  te: { bcp47: "te-IN", scripts: ["telugu"] },
  fa: { bcp47: "fa-IR", scripts: ["arabic"] },
  lv: { bcp47: "lv-LV", scripts: ["latin"] },
  bn: { bcp47: "bn-IN", scripts: ["bengali"] },
  sr: { bcp47: "sr-RS", scripts: ["cyrillic", "latin"] },
  az: { bcp47: "az-AZ", scripts: ["latin"] },
  sl: { bcp47: "sl-SI", scripts: ["latin"] },
  kn: { bcp47: "kn-IN", scripts: ["kannada"] },
  et: { bcp47: "et-EE", scripts: ["latin"] },
  mk: { bcp47: "mk-MK", scripts: ["cyrillic"] },
  br: { bcp47: "br-FR", scripts: ["latin"] },
  eu: { bcp47: "eu-ES", scripts: ["latin"] },
  is: { bcp47: "is-IS", scripts: ["latin"] },
  hy: { bcp47: "hy-AM", scripts: ["armenian"] },
  ne: { bcp47: "ne-NP", scripts: ["devanagari"] },
  mn: { bcp47: "mn-MN", scripts: ["cyrillic"] },
  bs: { bcp47: "bs-BA", scripts: ["latin"] },
  kk: { bcp47: "kk-KZ", scripts: ["cyrillic"] },
  sq: { bcp47: "sq-AL", scripts: ["latin"] },
  sw: { bcp47: "sw-KE", scripts: ["latin"] },
  gl: { bcp47: "gl-ES", scripts: ["latin"] },
  mr: { bcp47: "mr-IN", scripts: ["devanagari"] },
  pa: { bcp47: "pa-IN", scripts: ["gurmukhi"] },
  si: { bcp47: "si-LK", scripts: ["sinhala"] },
  km: { bcp47: "km-KH", scripts: ["khmer"] },
  sn: { bcp47: "sn-ZW", scripts: ["latin"] },
  yo: { bcp47: "yo-NG", scripts: ["latin"] },
  so: { bcp47: "so-SO", scripts: ["latin"] },
  af: { bcp47: "af-ZA", scripts: ["latin"] },
  oc: { bcp47: "oc-FR", scripts: ["latin"] },
  ka: { bcp47: "ka-GE", scripts: ["georgian"] },
  be: { bcp47: "be-BY", scripts: ["cyrillic"] },
  tg: { bcp47: "tg-TJ", scripts: ["cyrillic"] },
  sd: { bcp47: "sd-PK", scripts: ["arabic"] },
  gu: { bcp47: "gu-IN", scripts: ["gujarati"] },
  am: { bcp47: "am-ET", scripts: ["ethiopic"] },
  yi: { bcp47: "yi", scripts: ["hebrew"] },
  lo: { bcp47: "lo-LA", scripts: ["lao"] },
  uz: { bcp47: "uz-UZ", scripts: ["latin"] },
  fo: { bcp47: "fo-FO", scripts: ["latin"] },
  ht: { bcp47: "ht-HT", scripts: ["latin"] },
  ps: { bcp47: "ps-AF", scripts: ["arabic"] },
  tk: { bcp47: "tk-TM", scripts: ["latin"] },
  nn: { bcp47: "nn-NO", scripts: ["latin"] },
  mt: { bcp47: "mt-MT", scripts: ["latin"] },
  sa: { bcp47: "sa-IN", scripts: ["devanagari"] },
  lb: { bcp47: "lb-LU", scripts: ["latin"] },
  my: { bcp47: "my-MM", scripts: ["myanmar"] },
  bo: { bcp47: "bo-CN", scripts: ["tibetan"] },
  tl: { bcp47: "tl-PH", scripts: ["latin"] },
  mg: { bcp47: "mg-MG", scripts: ["latin"] },
  as: { bcp47: "as-IN", scripts: ["bengali"] },
  tt: { bcp47: "tt-RU", scripts: ["cyrillic"] },
  haw: { bcp47: "haw-US", scripts: ["latin"] },
  ln: { bcp47: "ln-CD", scripts: ["latin"] },
  ha: { bcp47: "ha-NG", scripts: ["latin"] },
  ba: { bcp47: "ba-RU", scripts: ["cyrillic"] },
  // ISO 639-1 переименовал яванский из "jw" в "jv" ещё в 2001-м; в задаче
  // код указан как "jw" — оставляем его кодом приложения (это то, что уже
  // могло уйти в базу и в контент), а провайдеру шлём современный "jv".
  jw: { bcp47: "jv-ID", scripts: ["latin"] },
  su: { bcp47: "su-ID", scripts: ["latin"] },
  // Кантонский от письменного путунхуа устной речью не отличить по
  // письменности — тот же han. Разделить их может только сам провайдер по
  // звучанию, если его модель это умеет; наша проверка — нет.
  yue: { bcp47: "yue-Hant-HK", scripts: ["han"] },
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
  ["armenian", /[԰-֏]/],
  ["georgian", /[Ⴀ-ჿᲐ-Ჿ]/],
  ["devanagari", /[ऀ-ॿ]/],
  ["bengali", /[ঀ-৿]/],
  ["gurmukhi", /[਀-੿]/],
  ["gujarati", /[઀-૿]/],
  ["tamil", /[஀-௿]/],
  ["telugu", /[ఀ-౿]/],
  ["kannada", /[ಀ-೿]/],
  ["malayalam", /[ഀ-ൿ]/],
  ["sinhala", /[඀-෿]/],
  ["thai", /[฀-๿]/],
  ["lao", /[຀-໿]/],
  ["khmer", /[ក-៿]/],
  ["myanmar", /[က-႟]/],
  ["tibetan", /[ༀ-࿿]/],
  ["ethiopic", /[ሀ-፿]/],
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
