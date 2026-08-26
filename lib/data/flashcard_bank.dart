/// Одно слово-карточка: одно и то же понятие на трёх языках (RU/EN/ES).
class FlashcardEntry {
  final String ru;
  final String en;
  final String es;

  const FlashcardEntry({required this.ru, required this.en, required this.es});

  String forLanguage(String languageCode) {
    switch (languageCode) {
      case 'ru':
        return ru;
      case 'es':
        return es;
      case 'en':
      default:
        return en;
    }
  }
}

/// Банк слов для режима «Тренировка» (задача итерации: карточки со словами
/// на языковой паре из профиля). Количество слов сознательно небольшое —
/// 10 штук, расширение банка не входит в объём этого захода.
class FlashcardBank {
  FlashcardBank._();

  static const List<FlashcardEntry> words = [
    FlashcardEntry(ru: 'дом', en: 'house', es: 'casa'),
    FlashcardEntry(ru: 'вода', en: 'water', es: 'agua'),
    FlashcardEntry(ru: 'книга', en: 'book', es: 'libro'),
    FlashcardEntry(ru: 'друг', en: 'friend', es: 'amigo'),
    FlashcardEntry(ru: 'работа', en: 'work', es: 'trabajo'),
    FlashcardEntry(ru: 'время', en: 'time', es: 'tiempo'),
    FlashcardEntry(ru: 'город', en: 'city', es: 'ciudad'),
    FlashcardEntry(ru: 'еда', en: 'food', es: 'comida'),
    FlashcardEntry(ru: 'солнце', en: 'sun', es: 'sol'),
    FlashcardEntry(ru: 'дорога', en: 'road', es: 'camino'),
  ];

  static int get count => words.length;
}
