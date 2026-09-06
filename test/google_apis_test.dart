import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Три сервиса Google (распознавание, синтез, модель) ходят под одним
/// ключом и настраиваются переменными окружения. Проверки читают САМИ
/// файлы функций: числа и имена переменных, переписанные в тест копией,
/// однажды отстанут молча, а расхождение здесь выглядит как «ничего не
/// работает и непонятно почему».
void main() {
  String read(String path) => File(path).readAsStringSync();

  String key() => read('supabase/functions/_shared/googleKey.ts');
  String tts() => read('supabase/functions/_shared/tts.ts');
  String speak() => read('supabase/functions/synthesize-speech/index.ts');

  test('ключ берётся свой, потом общий', () {
    final s = key();
    // Порядок важен: сначала переменная сервиса, потом общая. Обратный
    // порядок сделал бы переопределение на сервис бесполезным — а именно
    // оно спасает, когда один ключ на все три не принимается.
    expect(s, contains('TTS_API_KEY'));
    expect(s, contains('GOOGLE_API_KEY'));
    // Ключа модели здесь быть НЕ ДОЛЖНО: провайдер модели не обязан быть
    // Google, и его ключ резолвится в llmChat — см. тест ниже.
    expect(s.contains('LLM_API_KEY'), isFalse);
    expect(s.indexOf('const own = Deno.env.get(SPECIFIC[service]);'),
        lessThan(s.indexOf('const shared = Deno.env.get("GOOGLE_API_KEY");')));
  });

  test('синтез ходит через резолвер ключа', () {
    // Прямое чтение переменной в обход резолвера отняло бы возможность
    // сузить ключ до одного сервиса, не трогая код.
    expect(read('supabase/functions/_shared/tts.ts'), contains('googleKey('));
  });





  test('озвучка ограничена по длине и по языку', () {
    expect(tts(), contains('MAX_TTS_CHARS = 1000'));
    // Язык приходит снаружи и сверяется с парой игрока: определять его по
    // самому тексту нельзя, на короткой фразе это ошибается.
    expect(tts(), contains('isKnownLanguage(languageCode)'));
    expect(speak(), contains("eq('role', 'learning')".replaceAll("'", '"')));
    expect(speak(), contains('язык не совпадает с парой игрока'));
  });

  test('озвучка не тратит энергию', () {
    // Энергия платит за ответы, которые двигают раунд. Прослушивание —
    // справка, и брать за неё плату значило бы наказывать за попытку
    // разобраться.
    expect(speak().contains('spend_energy'), isFalse);
  });
}
