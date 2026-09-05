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
  String llm() => read('supabase/functions/_shared/llmChat.ts');
  String tts() => read('supabase/functions/_shared/tts.ts');
  String speak() => read('supabase/functions/synthesize-speech/index.ts');

  test('ключ берётся свой, потом общий', () {
    final s = key();
    // Порядок важен: сначала переменная сервиса, потом общая. Обратный
    // порядок сделал бы переопределение на сервис бесполезным — а именно
    // оно спасает, когда один ключ на все три не принимается.
    expect(s, contains('ASR_API_KEY'));
    expect(s, contains('TTS_API_KEY'));
    expect(s, contains('GOOGLE_API_KEY'));
    // Ключа модели здесь быть НЕ ДОЛЖНО: провайдер модели не обязан быть
    // Google, и его ключ резолвится в llmChat — см. тест ниже.
    expect(s.contains('LLM_API_KEY'), isFalse);
    expect(s.indexOf('const own = Deno.env.get(SPECIFIC[service]);'),
        lessThan(s.indexOf('const shared = Deno.env.get("GOOGLE_API_KEY");')));
  });

  test('оба сервиса Google ходят через общий резолвер ключа', () {
    // Прямое чтение своей переменной в обход резолвера вернуло бы прежнюю
    // болезнь: один ключ пришлось бы заводить дважды.
    for (final path in [
      'supabase/functions/_shared/asr/index.ts',
      'supabase/functions/_shared/tts.ts',
    ]) {
      expect(read(path), contains('googleKey('), reason: path);
    }
  });

  test('ключ Google не уходит стороннему провайдеру модели', () {
    // САМАЯ ДОРОГАЯ ОШИБКА В ЭТОМ ФАЙЛЕ. Ключ модели одно время резолвился
    // как ключ Google, с откатом на общий GOOGLE_API_KEY. Пока провайдер
    // был Gemini, это работало; со сторонним провайдером мы бы отправили
    // чужому получателю рабочий Cloud-ключ от распознавания и синтеза.
    // Отсюда проверка провайдера ПЕРЕД откатом на общий ключ.
    final s = llm();
    expect(s, contains('export function llmKey()'));
    expect(s.indexOf('if (llmProvider() !== "gemini") return null;'),
        lessThan(s.indexOf('const shared = Deno.env.get("GOOGLE_API_KEY");')));
    // Судья и разбор не должны знать про googleKey вовсе: единственная
    // точка, где решается ключ модели, — llmKey.
    for (final path in [
      'supabase/functions/_shared/evaluateGrammar.ts',
      'supabase/functions/_shared/explainElements.ts',
    ]) {
      expect(read(path), contains('llmKey()'), reason: path);
      expect(read(path).contains('googleKey('), isFalse, reason: path);
    }
  });

  test('по умолчанию провайдер — openai-совместимый, Gemini включается переменной', () {
    final s = llm();
    expect(s, contains('Deno.env.get("LLM_PROVIDER") ?? "openai"'));
    expect(s, contains('/chat/completions'));
    // Путь до Gemini остаётся рабочим: возврат к нему — это переменная, а
    // не правка кода, ради чего адаптер и писался.
    expect(s, contains('https://generativelanguage.googleapis.com/v1beta'));
    expect(s, contains(':generateContent'));
  });

  test('у модели нет значения по умолчанию', () {
    // Однажды здесь стояло имя несуществующей модели, и каждый вызов молча
    // падал с model_not_found. Отсутствие настройки должно быть явной
    // ошибкой, а не «работающим» значением.
    expect(llm(), contains('LLM_MODEL is not configured'));
    expect(llm().contains('LLM_MODEL") ?? "gemini'), isFalse);
  });

  test('Gemini просят отвечать строгим JSON', () {
    // От формата ответа зависит балл за раунд: без responseMimeType модель
    // вправе обернуть JSON в markdown, и разбор развалится.
    expect(llm(), contains('responseMimeType: "application/json"'));
    expect(llm(), contains('systemInstruction'));
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
