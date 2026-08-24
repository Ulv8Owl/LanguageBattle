import 'dart:math';

/// Заготовленный банк фраз (раздел 3 спеки: "не обязательно через
/// нейросеть — можно один раз собрать банк фраз вручную"). Фаза 2 заменит
/// это на реальный вызов LLM/банк из БД без изменения контракта, которым
/// пользуется battle-экран: [PhraseBank.pick].
class PhraseBank {
  PhraseBank._();

  static final Random _random = Random();

  static const Map<String, List<String>> _phrasesByLanguage = {
    'en': [
      'I would like a cup of coffee, please.',
      'Where is the nearest train station?',
      'She has been living here for three years.',
      'Could you repeat that a bit slower?',
      'We are planning a trip next summer.',
      'He forgot his umbrella at the office.',
      'This restaurant is famous for its seafood.',
      'I have never been to Japan before.',
      'The meeting was postponed until Friday.',
      'They usually go for a walk after dinner.',
      'My brother is learning to play the guitar.',
      'Can you help me carry these bags?',
      'It rained heavily all night long.',
      'I need to buy some fresh vegetables.',
      'The children were playing in the park.',
    ],
    'es': [
      'Me gustaría un café, por favor.',
      '¿Dónde está la estación de tren más cercana?',
      'Ella ha vivido aquí durante tres años.',
      '¿Podrías repetirlo un poco más despacio?',
      'Estamos planeando un viaje el próximo verano.',
      'Él olvidó su paraguas en la oficina.',
      'Este restaurante es famoso por sus mariscos.',
      'Nunca he estado en Japón.',
      'La reunión se pospuso hasta el viernes.',
      'Ellos suelen dar un paseo después de cenar.',
      'Mi hermano está aprendiendo a tocar la guitarra.',
      '¿Puedes ayudarme a llevar estas bolsas?',
      'Llovió mucho durante toda la noche.',
      'Necesito comprar verduras frescas.',
      'Los niños jugaban en el parque.',
    ],
    'ru': [
      'Я бы хотел чашку кофе, пожалуйста.',
      'Где находится ближайшая станция метро?',
      'Она живёт здесь уже три года.',
      'Не могли бы вы повторить чуть медленнее?',
      'Мы планируем поездку на следующее лето.',
      'Он забыл зонт в офисе.',
      'Этот ресторан славится морепродуктами.',
      'Я никогда не был в Японии.',
      'Встречу перенесли на пятницу.',
      'Они обычно гуляют после ужина.',
      'Мой брат учится играть на гитаре.',
      'Можешь помочь мне донести эти сумки?',
      'Всю ночь шёл сильный дождь.',
      'Мне нужно купить свежих овощей.',
      'Дети играли в парке.',
    ],
  };

  static List<String> _forLanguage(String languageCode) {
    return _phrasesByLanguage[languageCode] ?? _phrasesByLanguage['en']!;
  }

  /// Picks a phrase for [languageCode]. [roundNumber] is used to cycle
  /// deterministically through the bank first, then falls back to random
  /// once every phrase has been used at least once — good enough for a
  /// 10-round test match without immediate repeats.
  static String pick(String languageCode, int roundNumber) {
    final phrases = _forLanguage(languageCode);
    if (roundNumber <= phrases.length) {
      return phrases[(roundNumber - 1) % phrases.length];
    }
    return phrases[_random.nextInt(phrases.length)];
  }
}
