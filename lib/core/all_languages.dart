/// Единственный список языков во всём приложении.
///
/// Раньше их было четыре: languageNames в languages.dart (что можно
/// учить), _supportedLanguages в онбординге, _supportedLanguages в выборе
/// языковой пары и две карты флагов в Профиле и Друзьях. Любое добавление
/// языка требовало вспомнить про все пять мест, и они уже начали
/// расходиться. Теперь язык описывается здесь один раз — и появляется
/// везде.
///
/// СКОЛЬКО ЯЗЫКОВ И ПОЧЕМУ ИМЕННО ЭТИ. Список ограничен 32 языками
/// осознанно, а не «пока руки не дошли». Три причины, каждая из которых
/// растёт линейно с числом языков:
///
///   * контент. Один язык — это 100 фраз и 1000 слов ТОЛЬКО на уровень A1,
///     а полный банк это шесть уровней. Сотня языков означала бы сотню
///     таких банков, каждый из которых нужно кому-то вычитать;
///   * ликвидность PvP. Каждая языковая пара дробит очередь матчмейкинга.
///     Сто языков — это гарантированно пустые очереди в Состязании и
///     Дуэли, то есть режим, который не работает ни для кого;
///   * распознавание речи. Провайдер обязан уметь язык, иначе игровой
///     цикл для него просто не замыкается.
///
/// Отбор — по покрытию жалоб, а не по числу строк: сюда входят ВСЕ
/// двенадцать самых изучаемых языков мира (никто не скажет «моего
/// изучаемого нет»), крупнейшие рынки по числу носителей и вся Европа,
/// какую разумно закрыть.
///
/// Сознательно НЕ включены (это решение, а не забывчивость):
///   * малайский — взаимопонятен с индонезийским, который здесь есть;
///   * тамильский, телугу, маратхи, гуджарати, панджаби, каннада — Индия
///     закрыта хинди/бенгальским/урду, а региональные языки там учат
///     через английский;
///   * кантонский — на письме совпадает с путунхуа, различает их только
///     провайдер и только на слух;
///   * яванский, сунданский — их носители практически поголовно владеют
///     индонезийским;
///   * суахили, хауса, йоруба — Африка как рынок роста интересна, но
///     качество ASR и монетизация пока хуже; кандидаты второй волны;
///   * сербский, хорватский, боснийский, словацкий, словенский,
///     болгарский, литовский, латышский, эстонский — кандидаты второй
///     волны, когда контент-конвейер себя окупит.
///
/// Порядок и набор кодов ДОЛЖНЫ совпадать с LANGUAGES в
/// supabase/functions/_shared/asr/languages.ts — там та же таблица нужна
/// распознаванию речи (тег провайдера и письменность). Совпадение
/// проверяется тестом test/languages_test.dart, а не только вниманием.
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
  devanagari,
  bengali,
  thai,
  han,
  kana,
  hangul,
}

class LanguageInfo {
  /// Название на самом языке — то, что видит игрок («Deutsch», не
  /// «немецкий»): свой язык человек узнаёт в списке быстрее всего именно
  /// в таком виде.
  final String endonym;

  /// Название в винительном падеже для русских подписей: «Переведи на
  /// английский», «нужно перевести на хинди». Несклоняемые языки (хинди,
  /// урду, иврит) подставляются как есть — шаблоны это учитывают и не
  /// дописывают «язык» после названия.
  final String accusative;

  /// Как назвать речь на этом языке: «английской речи», «речи на хинди».
  /// Готовая форма, а не склонение на лету, — см. recognisingSpeechLabel
  /// в languages.dart: у несклоняемых названий прилагательного нет вовсе.
  final String speech;

  /// Флаг для плашек языковых пар и карточек игроков. Привязка языка к
  /// одной стране всегда условна — у английского, испанского,
  /// португальского и арабского стран много; берём страну происхождения,
  /// как уже было заведено в проекте для en/es/ru.
  final String flag;

  final List<Script> scripts;

  const LanguageInfo({
    required this.endonym,
    required this.accusative,
    required this.speech,
    required this.flag,
    required this.scripts,
  });
}

/// 32 языка: 12 самых изучаемых + крупнейшие рынки носителей + Европа.
const Map<String, LanguageInfo> allLanguages = {
  // --- Эшелон A: топ-12 изучаемых в мире и крупнейшие рынки ---
  'en': LanguageInfo(endonym: 'English', accusative: 'английский', speech: 'английской речи', flag: '🇬🇧', scripts: [Script.latin]),
  'es': LanguageInfo(endonym: 'Español', accusative: 'испанский', speech: 'испанской речи', flag: '🇪🇸', scripts: [Script.latin]),
  'zh': LanguageInfo(endonym: '中文', accusative: 'китайский', speech: 'китайской речи', flag: '🇨🇳', scripts: [Script.han]),
  'hi': LanguageInfo(endonym: 'हिन्दी', accusative: 'хинди', speech: 'речи на хинди', flag: '🇮🇳', scripts: [Script.devanagari]),
  'ar': LanguageInfo(endonym: 'العربية', accusative: 'арабский', speech: 'арабской речи', flag: '🇸🇦', scripts: [Script.arabic]),
  'pt': LanguageInfo(endonym: 'Português', accusative: 'португальский', speech: 'португальской речи', flag: '🇵🇹', scripts: [Script.latin]),
  'ru': LanguageInfo(endonym: 'Русский', accusative: 'русский', speech: 'русской речи', flag: '🇷🇺', scripts: [Script.cyrillic]),
  'fr': LanguageInfo(endonym: 'Français', accusative: 'французский', speech: 'французской речи', flag: '🇫🇷', scripts: [Script.latin]),
  'de': LanguageInfo(endonym: 'Deutsch', accusative: 'немецкий', speech: 'немецкой речи', flag: '🇩🇪', scripts: [Script.latin]),
  'ja': LanguageInfo(endonym: '日本語', accusative: 'японский', speech: 'японской речи', flag: '🇯🇵', scripts: [Script.kana, Script.han]),
  'ko': LanguageInfo(endonym: '한국어', accusative: 'корейский', speech: 'корейской речи', flag: '🇰🇷', scripts: [Script.hangul]),
  'it': LanguageInfo(endonym: 'Italiano', accusative: 'итальянский', speech: 'итальянской речи', flag: '🇮🇹', scripts: [Script.latin]),

  // --- Эшелон B: большие базы носителей и растущие мобильные рынки ---
  'id': LanguageInfo(endonym: 'Bahasa Indonesia', accusative: 'индонезийский', speech: 'индонезийской речи', flag: '🇮🇩', scripts: [Script.latin]),
  'tr': LanguageInfo(endonym: 'Türkçe', accusative: 'турецкий', speech: 'турецкой речи', flag: '🇹🇷', scripts: [Script.latin]),
  'vi': LanguageInfo(endonym: 'Tiếng Việt', accusative: 'вьетнамский', speech: 'вьетнамской речи', flag: '🇻🇳', scripts: [Script.latin]),
  'pl': LanguageInfo(endonym: 'Polski', accusative: 'польский', speech: 'польской речи', flag: '🇵🇱', scripts: [Script.latin]),
  'nl': LanguageInfo(endonym: 'Nederlands', accusative: 'нидерландский', speech: 'нидерландской речи', flag: '🇳🇱', scripts: [Script.latin]),
  'th': LanguageInfo(endonym: 'ไทย', accusative: 'тайский', speech: 'тайской речи', flag: '🇹🇭', scripts: [Script.thai]),
  'uk': LanguageInfo(endonym: 'Українська', accusative: 'украинский', speech: 'украинской речи', flag: '🇺🇦', scripts: [Script.cyrillic]),
  'fa': LanguageInfo(endonym: 'فارسی', accusative: 'персидский', speech: 'персидской речи', flag: '🇮🇷', scripts: [Script.arabic]),
  'bn': LanguageInfo(endonym: 'বাংলা', accusative: 'бенгальский', speech: 'бенгальской речи', flag: '🇧🇩', scripts: [Script.bengali]),
  'ur': LanguageInfo(endonym: 'اردو', accusative: 'урду', speech: 'речи на урду', flag: '🇵🇰', scripts: [Script.arabic]),

  // --- Эшелон C: остальная Европа и Филиппины ---
  'sv': LanguageInfo(endonym: 'Svenska', accusative: 'шведский', speech: 'шведской речи', flag: '🇸🇪', scripts: [Script.latin]),
  'no': LanguageInfo(endonym: 'Norsk', accusative: 'норвежский', speech: 'норвежской речи', flag: '🇳🇴', scripts: [Script.latin]),
  'da': LanguageInfo(endonym: 'Dansk', accusative: 'датский', speech: 'датской речи', flag: '🇩🇰', scripts: [Script.latin]),
  'fi': LanguageInfo(endonym: 'Suomi', accusative: 'финский', speech: 'финской речи', flag: '🇫🇮', scripts: [Script.latin]),
  'cs': LanguageInfo(endonym: 'Čeština', accusative: 'чешский', speech: 'чешской речи', flag: '🇨🇿', scripts: [Script.latin]),
  'el': LanguageInfo(endonym: 'Ελληνικά', accusative: 'греческий', speech: 'греческой речи', flag: '🇬🇷', scripts: [Script.greek]),
  'he': LanguageInfo(endonym: 'עברית', accusative: 'иврит', speech: 'речи на иврите', flag: '🇮🇱', scripts: [Script.hebrew]),
  'ro': LanguageInfo(endonym: 'Română', accusative: 'румынский', speech: 'румынской речи', flag: '🇷🇴', scripts: [Script.latin]),
  'hu': LanguageInfo(endonym: 'Magyar', accusative: 'венгерский', speech: 'венгерской речи', flag: '🇭🇺', scripts: [Script.latin]),
  'tl': LanguageInfo(endonym: 'Tagalog', accusative: 'тагальский', speech: 'тагальской речи', flag: '🇵🇭', scripts: [Script.latin]),
};

/// Название языка для интерфейса, с честным запасным вариантом: код языка
/// лучше пустоты, если в базе оказался код вне списка (например, остался
/// от старой сборки).
String languageName(String? code) =>
    code == null ? '—' : allLanguages[code]?.endonym ?? code;

/// Флаг языка. 🏳 — не «ошибка», а «языка нет в списке»: то же правило,
/// что и у languageName.
String languageFlag(String? code) =>
    code == null ? '🏳' : allLanguages[code]?.flag ?? '🏳';
