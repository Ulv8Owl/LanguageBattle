import 'package:flutter_test/flutter_test.dart';

import 'package:language_battle/data/speech_playback.dart';

/// Отказ озвучки приходит с сервера уже человеческим текстом («нет ключа»,
/// «язык не совпадает с парой»), но приезжает он внутри текста исключения
/// клиента Supabase. Если распаковка сломается, игрок увидит стек вместо
/// причины — и чинить пойдёт не туда.
void main() {
  test('причина достаётся из тела ответа функции', () {
    final reason = SpeechPlayback.reasonFrom(
      Exception('FunctionException: {"error":"язык не совпадает с парой игрока"}'),
    );
    expect(reason, 'язык не совпадает с парой игрока');
  });

  test('без поля error возвращается сам текст ошибки', () {
    // Сетевой сбой до сервера: тела нет вовсе, и придумывать причину
    // нельзя — пусть игрок видит то, что случилось на самом деле.
    final reason = SpeechPlayback.reasonFrom(Exception('SocketException: нет сети'));
    expect(reason, contains('SocketException'));
  });
}
