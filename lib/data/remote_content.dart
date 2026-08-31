import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

/// Брошено, когда контент физически негде взять — ни с гита, ни из кэша на
/// диске, ни из бандла приложения.
///
/// ОТЛИЧАЕТСЯ от сетевой ошибки, которую этот класс всегда переживает сам:
/// сеть может быть недоступна ВРЕМЕННО (тогда спасает диск), а этого файла
/// может не быть вовсе — например, для языка, для которого контент ещё не
/// сгенерирован. Второй случай — не поломка, а ожидаемое состояние: экраны
/// ловят это исключение и показывают заглушку «для этого языка пока нет
/// материала», а не текст об ошибке.
class ContentUnavailable implements Exception {
  final String repoPath;
  const ContentUnavailable(this.repoPath);
  @override
  String toString() => 'ContentUnavailable($repoPath)';
}

/// Источник фраз и слов Тренировки/раундов — этот же репозиторий на
/// GitHub, а не Supabase (там ограничено место, и хранение статичного
/// игрового контента — не его задача) и не сам APK.
///
/// Раньше файлы assets/phrases/*.json и assets/vocab/*.json лежали
/// БАНДЛОМ — компилировались прямо в приложение. Это работало, пока языков
/// было три, но перестаёт масштабироваться, когда их десятки: каждый новый
/// язык увеличивает APK, хотя сам контент никак не связан с версией кода и
/// в идеале должен обновляться независимо от релиза приложения.
///
/// Теперь тот же самый JSON тянется в рантайме с raw.githubusercontent.com
/// и кэшируется на диск устройства — второй и все следующие запуски читают
/// уже скачанное, а не ходят в сеть заново. Бандл (rootBundle) остался
/// последней линией обороны для файлов, которые в нём физически есть
/// (сейчас — только исходные assets/phrases и assets/vocab с en/ru/es):
/// если и сеть недоступна, и кэша ещё нет, это не даст экрану остаться
/// совсем без данных на самом первом запуске игры.
///
/// Порядок попыток: сеть -> диск -> бандл -> ContentUnavailable.
class RemoteContent {
  RemoteContent._();

  /// Ветка репозитория, из которой тянуть контент. Задаётся при сборке
  /// (--dart-define=CONTENT_BRANCH=...), а не хардкодится: релизная сборка
  /// должна брать проверенный контент из main, а разработка — свежий из
  /// той ветки, где он только что дописан.
  static const String _branch = String.fromEnvironment('CONTENT_BRANCH', defaultValue: 'main');

  static const String _rawBase = 'https://raw.githubusercontent.com/Ulv8Owl/LanguageBattle';

  /// Короткий таймаут: это не критичный путь (диск и бандл подстрахуют), и
  /// вешать экран на общий сетевой таймаут ради необязательного апдейта
  /// контента незачем.
  static const Duration _timeout = Duration(seconds: 8);

  /// Кэш на процесс — тот же принцип, что уже был в PhraseBank/FlashcardBank
  /// до этого класса: контент неизменен в рамках одного запуска игры,
  /// перечитывать файл на каждое обращение незачем.
  static final Map<String, dynamic> _memory = {};

  /// [repoPath] — путь от корня репозитория, например
  /// 'assets/phrases/phrases_a1.json'. Один и тот же путь служит именем
  /// файла в кэше на диске (с заменой '/' на '_') и путём в rootBundle —
  /// так смена схемы каталогов ломает все три источника разом при первой
  /// же проверке, а не расходится по одному незаметно.
  static Future<dynamic> loadJson(String repoPath) async {
    final cached = _memory[repoPath];
    if (cached != null) return cached;

    String? raw = await _fetchAndCache(repoPath);
    raw ??= await _readCache(repoPath);
    raw ??= await _readBundled(repoPath);

    if (raw == null) throw ContentUnavailable(repoPath);
    final decoded = jsonDecode(raw);
    _memory[repoPath] = decoded;
    return decoded;
  }

  /// Тот же путь есть хоть где-то — с гита, на диске или в бандле?
  ///
  /// НЕ ходит в сеть намеренно: используется там, где нужно быстро
  /// перечислить, для каких языков контент вообще существует (например,
  /// список языков в выборе колоды Тренировки), и ждать сетевой таймаут на
  /// каждый из полусотни языков было бы слишком долго. Сетевая проверка
  /// произойдёт позже, в самом loadJson, когда файл реально понадобится.
  static Future<bool> existsLocally(String repoPath) async {
    if (_memory.containsKey(repoPath)) return true;
    if (await _readCache(repoPath) != null) return true;
    return await _readBundled(repoPath) != null;
  }

  static Future<String?> _fetchAndCache(String repoPath) async {
    try {
      final res = await http.get(Uri.parse('$_rawBase/$_branch/$repoPath')).timeout(_timeout);
      if (res.statusCode != 200) return null;
      final raw = utf8.decode(res.bodyBytes);
      await _writeCache(repoPath, raw);
      return raw;
    } catch (_) {
      // Сеть недоступна, таймаут, DNS — что угодно. Дальше по цепочке
      // попробуют диск и бандл; бросать здесь нечего.
      return null;
    }
  }

  static Future<File> _cacheFile(String repoPath) async {
    final dir = await getApplicationSupportDirectory();
    final safeName = repoPath.replaceAll('/', '_');
    return File('${dir.path}/content_cache/$safeName');
  }

  static Future<void> _writeCache(String repoPath, String raw) async {
    try {
      final file = await _cacheFile(repoPath);
      await file.parent.create(recursive: true);
      await file.writeAsString(raw);
    } catch (_) {
      // Кэш — оптимизация, а не обязанность. Не удалось записать (нет
      // места, нет прав) — контент всё равно уже получен из сети и вернётся
      // из памяти в этом запуске; на следующем просто скачается заново.
    }
  }

  static Future<String?> _readCache(String repoPath) async {
    try {
      final file = await _cacheFile(repoPath);
      if (await file.exists()) return await file.readAsString();
    } catch (_) {
      // Повреждённый файл кэша — не повод падать, просто пробуем дальше.
    }
    return null;
  }

  static Future<String?> _readBundled(String repoPath) async {
    try {
      return await rootBundle.loadString(repoPath);
    } catch (_) {
      return null;
    }
  }
}
