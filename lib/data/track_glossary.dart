import 'remote_content.dart';

/// Словарь трека: перевод каждого слова, написанный руками.
///
/// ЗАЧЕМ ОТДЕЛЬНЫЙ ФАЙЛ, КОГДА ПЕРЕВОД ЕСТЬ В РАЗМЕТКЕ. Разметка — это
/// JSON, и переводить в нём десятки строк подряд мучительно: одна забытая
/// запятая, и файл перестаёт читаться целиком. Здесь простой текст, одна
/// строка на слово, и сломать его нечем.
///
/// СЛОВА СОПОСТАВЛЯЮТСЯ ПО ПОРЯДКУ, а не по тексту. Одно и то же слово
/// встречается в записи десятки раз и в разных местах значит разное; по
/// тексту их не различить, а по месту — всегда. Слово слева нужно человеку,
/// чтобы видеть, где он находится; программа смотрит на номер строки.
///
/// Формат:
///
///     hello = привет
///     world = мир
///     the =
///
/// Разделителем годится знак равенства, табуляция или дефис, окружённый
/// пробелами. Пустой перевод — это «перевода нет»: артикль переводить
/// нечем, и пустая строка под словом честнее выдуманной.
class TrackGlossary {
  /// Переводы по порядку слов. Пустая строка означает «перевода нет».
  final List<String?> byIndex;

  const TrackGlossary(this.byIndex);

  static String path(String trackId) => 'assets/tracks/$trackId.words.txt';

  bool get isEmpty => byIndex.isEmpty;

  /// Перевод слова номер [index] или null.
  String? at(int index) =>
      index >= 0 && index < byIndex.length ? byIndex[index] : null;

  /// Читает словарь трека. null — файла нет, и это нормально.
  static Future<TrackGlossary?> load(String trackId) async {
    final raw = await RemoteContent.loadText(path(trackId));
    if (raw == null) return null;
    final parsed = parse(raw);
    return parsed.isEmpty ? null : parsed;
  }

  /// Разбор — отдельно от чтения, чтобы его можно было проверить тестом без
  /// файловой системы и без сети.
  static TrackGlossary parse(String raw) {
    final out = <String?>[];
    for (final line in raw.split('\n')) {
      final text = line.trim();
      // Пустые строки и комментарии не сдвигают нумерацию: иначе один
      // случайный перенос строки развалил бы весь перевод, начиная с него.
      if (text.isEmpty || text.startsWith('#')) continue;

      final translation = _afterSeparator(text);
      out.add(translation.isEmpty ? null : translation);
    }
    return TrackGlossary(out);
  }

  /// Всё, что идёт после разделителя. Разделителей несколько намеренно:
  /// файл правят руками, и требовать ровно один символ — значит ловить
  /// опечатки вместо переводов.
  static String _afterSeparator(String line) {
    for (final separator in ['\t', ' = ', '=', ' - ', ' — ', ' – ']) {
      final at = line.indexOf(separator);
      if (at < 0) continue;
      return line.substring(at + separator.length).trim();
    }
    // Разделителя нет вовсе — значит перевод ещё не написан.
    return '';
  }

  /// Заготовка для перевода: слова по порядку, переводы пустые.
  ///
  /// Выгружается из приложения (см. список треков): слова берутся из тех
  /// субтитров, которые к треку уже притянуты, — переписывать их руками не
  /// нужно.
  static String template(String trackId, List<String> words) {
    final buffer = StringBuffer()
      ..writeln('# Словарь трека $trackId')
      ..writeln('# Одна строка на слово, по порядку. Строки не переставлять и')
      ..writeln('# не удалять: слова сопоставляются по номеру строки.')
      ..writeln('# Пустой перевод — значит перевода нет, так тоже можно.')
      ..writeln();
    for (final word in words) {
      buffer.writeln('$word = ');
    }
    return buffer.toString();
  }
}
