/// Полный список языков, которые приложение УМЕЕТ ОПОЗНАТЬ — как родной
/// язык игрока, для проверки «не тот язык» (см. supabase/functions/_shared
/// /asr/languages.ts, зеркало этой таблицы на сервере) и как есть в
/// принципе.
///
/// Это НЕ список того, что можно ВЫБРАТЬ изучать: язык появляется в
/// [languageNames] (lib/core/languages.dart) только когда у него есть банк
/// фраз и слов. Разница принципиальна: человек может быть носителем языка,
/// для которого в игре ещё нет ни одного урока, — и тогда его родной язык
/// всё равно нужно правильно узнать (чтобы поймать «прочитал задание
/// вслух вместо перевода»), хотя учить на нём пока нечего.
///
/// Порядок и набор кодов ДОЛЖНЫ совпадать с LANGUAGES в
/// supabase/functions/_shared/asr/languages.ts — там та же таблица нужна
/// распознаванию речи. Изменения вносить в обоих местах.
library;

/// Письменность языка — та, в которой распознаватель речи ВЫДАЁТ текст на
/// этом языке (не «в которой язык бывает записан»: для японского это кана
/// и иероглифы, а не латиница, — транслитерацию ASR не возвращает).
enum Script {
  latin,
  cyrillic,
  greek,
  arabic,
  hebrew,
  armenian,
  georgian,
  devanagari,
  bengali,
  gurmukhi,
  gujarati,
  tamil,
  telugu,
  kannada,
  malayalam,
  sinhala,
  thai,
  lao,
  khmer,
  myanmar,
  tibetan,
  ethiopic,
  han,
  kana,
  hangul,
}

class LanguageInfo {
  /// Название на самом языке — то, что видит игрок («Deutsch», не
  /// «German»). Тот же принцип, что уже был в languageNames для en/es/ru.
  final String endonym;
  final List<Script> scripts;

  const LanguageInfo({required this.endonym, required this.scripts});
}

/// Ключ в англоязычной справочной паре из задачи — оставлен нигде не
/// используемым осознанно: он не нужен коду, endonym решает те же задачи и
/// показывается игроку. Держать англоязычные имена было бы дублированием,
/// которое ничего не проверяет и легко разъедется с endonym.
const Map<String, LanguageInfo> allLanguages = {
  'en': LanguageInfo(endonym: 'English', scripts: [Script.latin]),
  'es': LanguageInfo(endonym: 'Español', scripts: [Script.latin]),
  'ru': LanguageInfo(endonym: 'Русский', scripts: [Script.cyrillic]),
  'zh': LanguageInfo(endonym: '中文', scripts: [Script.han]),
  'de': LanguageInfo(endonym: 'Deutsch', scripts: [Script.latin]),
  'ko': LanguageInfo(endonym: '한국어', scripts: [Script.hangul]),
  'fr': LanguageInfo(endonym: 'Français', scripts: [Script.latin]),
  'ja': LanguageInfo(endonym: '日本語', scripts: [Script.kana, Script.han]),
  'pt': LanguageInfo(endonym: 'Português', scripts: [Script.latin]),
  'tr': LanguageInfo(endonym: 'Türkçe', scripts: [Script.latin]),
  'pl': LanguageInfo(endonym: 'Polski', scripts: [Script.latin]),
  'ca': LanguageInfo(endonym: 'Català', scripts: [Script.latin]),
  'nl': LanguageInfo(endonym: 'Nederlands', scripts: [Script.latin]),
  'ar': LanguageInfo(endonym: 'العربية', scripts: [Script.arabic]),
  'sv': LanguageInfo(endonym: 'Svenska', scripts: [Script.latin]),
  'it': LanguageInfo(endonym: 'Italiano', scripts: [Script.latin]),
  'id': LanguageInfo(endonym: 'Bahasa Indonesia', scripts: [Script.latin]),
  'hi': LanguageInfo(endonym: 'हिन्दी', scripts: [Script.devanagari]),
  'fi': LanguageInfo(endonym: 'Suomi', scripts: [Script.latin]),
  'vi': LanguageInfo(endonym: 'Tiếng Việt', scripts: [Script.latin]),
  'he': LanguageInfo(endonym: 'עברית', scripts: [Script.hebrew]),
  'uk': LanguageInfo(endonym: 'Українська', scripts: [Script.cyrillic]),
  'el': LanguageInfo(endonym: 'Ελληνικά', scripts: [Script.greek]),
  'ms': LanguageInfo(endonym: 'Bahasa Melayu', scripts: [Script.latin]),
  'cs': LanguageInfo(endonym: 'Čeština', scripts: [Script.latin]),
  'ro': LanguageInfo(endonym: 'Română', scripts: [Script.latin]),
  'da': LanguageInfo(endonym: 'Dansk', scripts: [Script.latin]),
  'hu': LanguageInfo(endonym: 'Magyar', scripts: [Script.latin]),
  'ta': LanguageInfo(endonym: 'தமிழ்', scripts: [Script.tamil]),
  'no': LanguageInfo(endonym: 'Norsk', scripts: [Script.latin]),
  'th': LanguageInfo(endonym: 'ไทย', scripts: [Script.thai]),
  'ur': LanguageInfo(endonym: 'اردو', scripts: [Script.arabic]),
  'hr': LanguageInfo(endonym: 'Hrvatski', scripts: [Script.latin]),
  'bg': LanguageInfo(endonym: 'Български', scripts: [Script.cyrillic]),
  'lt': LanguageInfo(endonym: 'Lietuvių', scripts: [Script.latin]),
  'la': LanguageInfo(endonym: 'Latina', scripts: [Script.latin]),
  'mi': LanguageInfo(endonym: 'Māori', scripts: [Script.latin]),
  'ml': LanguageInfo(endonym: 'മലയാളം', scripts: [Script.malayalam]),
  'cy': LanguageInfo(endonym: 'Cymraeg', scripts: [Script.latin]),
  'sk': LanguageInfo(endonym: 'Slovenčina', scripts: [Script.latin]),
  'te': LanguageInfo(endonym: 'తెలుగు', scripts: [Script.telugu]),
  'fa': LanguageInfo(endonym: 'فارسی', scripts: [Script.arabic]),
  'lv': LanguageInfo(endonym: 'Latviešu', scripts: [Script.latin]),
  'bn': LanguageInfo(endonym: 'বাংলা', scripts: [Script.bengali]),
  'sr': LanguageInfo(endonym: 'Српски', scripts: [Script.cyrillic, Script.latin]),
  'az': LanguageInfo(endonym: 'Azərbaycan', scripts: [Script.latin]),
  'sl': LanguageInfo(endonym: 'Slovenščina', scripts: [Script.latin]),
  'kn': LanguageInfo(endonym: 'ಕನ್ನಡ', scripts: [Script.kannada]),
  'et': LanguageInfo(endonym: 'Eesti', scripts: [Script.latin]),
  'mk': LanguageInfo(endonym: 'Македонски', scripts: [Script.cyrillic]),
  'br': LanguageInfo(endonym: 'Brezhoneg', scripts: [Script.latin]),
  'eu': LanguageInfo(endonym: 'Euskara', scripts: [Script.latin]),
  'is': LanguageInfo(endonym: 'Íslenska', scripts: [Script.latin]),
  'hy': LanguageInfo(endonym: 'Հայերեն', scripts: [Script.armenian]),
  'ne': LanguageInfo(endonym: 'नेपाली', scripts: [Script.devanagari]),
  'mn': LanguageInfo(endonym: 'Монгол', scripts: [Script.cyrillic]),
  'bs': LanguageInfo(endonym: 'Bosanski', scripts: [Script.latin]),
  'kk': LanguageInfo(endonym: 'Қазақша', scripts: [Script.cyrillic]),
  'sq': LanguageInfo(endonym: 'Shqip', scripts: [Script.latin]),
  'sw': LanguageInfo(endonym: 'Kiswahili', scripts: [Script.latin]),
  'gl': LanguageInfo(endonym: 'Galego', scripts: [Script.latin]),
  'mr': LanguageInfo(endonym: 'मराठी', scripts: [Script.devanagari]),
  'pa': LanguageInfo(endonym: 'ਪੰਜਾਬੀ', scripts: [Script.gurmukhi]),
  'si': LanguageInfo(endonym: 'සිංහල', scripts: [Script.sinhala]),
  'km': LanguageInfo(endonym: 'ខ្មែរ', scripts: [Script.khmer]),
  'sn': LanguageInfo(endonym: 'ChiShona', scripts: [Script.latin]),
  'yo': LanguageInfo(endonym: 'Yorùbá', scripts: [Script.latin]),
  'so': LanguageInfo(endonym: 'Soomaali', scripts: [Script.latin]),
  'af': LanguageInfo(endonym: 'Afrikaans', scripts: [Script.latin]),
  'oc': LanguageInfo(endonym: 'Occitan', scripts: [Script.latin]),
  'ka': LanguageInfo(endonym: 'ქართული', scripts: [Script.georgian]),
  'be': LanguageInfo(endonym: 'Беларуская', scripts: [Script.cyrillic]),
  'tg': LanguageInfo(endonym: 'Тоҷикӣ', scripts: [Script.cyrillic]),
  'sd': LanguageInfo(endonym: 'سنڌي', scripts: [Script.arabic]),
  'gu': LanguageInfo(endonym: 'ગુજરાતી', scripts: [Script.gujarati]),
  'am': LanguageInfo(endonym: 'አማርኛ', scripts: [Script.ethiopic]),
  'yi': LanguageInfo(endonym: 'ייִדיש', scripts: [Script.hebrew]),
  'lo': LanguageInfo(endonym: 'ລາວ', scripts: [Script.lao]),
  'uz': LanguageInfo(endonym: "O'zbek", scripts: [Script.latin]),
  'fo': LanguageInfo(endonym: 'Føroyskt', scripts: [Script.latin]),
  'ht': LanguageInfo(endonym: 'Kreyòl Ayisyen', scripts: [Script.latin]),
  'ps': LanguageInfo(endonym: 'پښتو', scripts: [Script.arabic]),
  'tk': LanguageInfo(endonym: 'Türkmen', scripts: [Script.latin]),
  'nn': LanguageInfo(endonym: 'Nynorsk', scripts: [Script.latin]),
  'mt': LanguageInfo(endonym: 'Malti', scripts: [Script.latin]),
  'sa': LanguageInfo(endonym: 'संस्कृतम्', scripts: [Script.devanagari]),
  'lb': LanguageInfo(endonym: 'Lëtzebuergesch', scripts: [Script.latin]),
  'my': LanguageInfo(endonym: 'မြန်မာ', scripts: [Script.myanmar]),
  'bo': LanguageInfo(endonym: 'བོད་སྐད་', scripts: [Script.tibetan]),
  'tl': LanguageInfo(endonym: 'Tagalog', scripts: [Script.latin]),
  'mg': LanguageInfo(endonym: 'Malagasy', scripts: [Script.latin]),
  'as': LanguageInfo(endonym: 'অসমীয়া', scripts: [Script.bengali]),
  'tt': LanguageInfo(endonym: 'Татар', scripts: [Script.cyrillic]),
  'haw': LanguageInfo(endonym: 'ʻŌlelo Hawaiʻi', scripts: [Script.latin]),
  'ln': LanguageInfo(endonym: 'Lingála', scripts: [Script.latin]),
  'ha': LanguageInfo(endonym: 'Hausa', scripts: [Script.latin]),
  'ba': LanguageInfo(endonym: 'Башҡорт', scripts: [Script.cyrillic]),
  'jw': LanguageInfo(endonym: 'Basa Jawa', scripts: [Script.latin]),
  'su': LanguageInfo(endonym: 'Basa Sunda', scripts: [Script.latin]),
  // Кантонский речью не отличить от письменного путунхуа (тот же han),
  // ASR по письменности их не разделит — только сам провайдер по звучанию.
  'yue': LanguageInfo(endonym: '粵語', scripts: [Script.han]),
};
