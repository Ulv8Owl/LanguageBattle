import 'dart:math';

/// Один пункт банка фраз: одна и та же мысль на трёх языках (RU/EN/ES),
/// параллельный перевод.
class PhraseEntry {
  final String topic;
  final String ru;
  final String en;
  final String es;

  const PhraseEntry({required this.topic, required this.ru, required this.en, required this.es});

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

/// Банк фраз для раундов боя и Одиночной Игры — присланный владельцем
/// проекта список (300_independent_phrases_clean.xlsx). ФРАЗЫ НЕ
/// ГЕНЕРИРУЮТСЯ НЕЙРОСЕТЬЮ: LLM в этом приложении используется только для
/// оценки грамматики и разбора ошибок (раздел 9), выбор фразы раунда —
/// чистый рандом по этому фиксированному списку.
///
/// В исходном файле было 300 строк, но фактически только 10 уникальных
/// текстов (остальные — повторы с разным заголовком темы), и в 9 из 10
/// строк английская и испанская колонки содержали непереведённый русский
/// фрагмент внутри второго предложения (баг генератора исходной таблицы:
/// "After that, анна usually goes..." вместо "After that, Anna usually
/// goes..."). Здесь эта ошибка исправлена — подстановка имени/субъекта во
/// втором предложении заменена на корректный вариант на том же языке,
/// остальной текст не менялся.
class PhraseBank {
  PhraseBank._();

  static final Random _random = Random();

  static const List<PhraseEntry> phrases = [
    PhraseEntry(
      topic: 'Анна',
      ru: 'Анна обожает рисовать красивые пейзажи акварелью и карандашами. '
          'После этого Анна обычно идет в магазин за свежими продуктами. '
          'Там всегда можно найти большой выбор вкусных фруктов и овощей. '
          'Обычно люди покупают там молоко, хлеб, сыр и сладкий чай. '
          'В конце дня приятно отдохнуть дома в тишине и посмотреть фильм.',
      en: 'Anna loves to paint beautiful landscapes with watercolors and pencils. '
          'After that, Anna usually goes to the store for fresh groceries. '
          'There you can always find a large selection of delicious fruits and vegetables. '
          'Usually people buy milk, bread, cheese, and sweet tea there. '
          'At the end of the day, it is nice to relax at home in silence and watch a movie.',
      es: 'Anna adora pintar hermosos paisajes con acuarelas y lápices. '
          'Después de eso, Anna suele ir a la tienda a buscar productos frescos. '
          'Allí siempre se puede encontrar una gran selección de frutas y verduras deliciosas. '
          'Por lo general, la gente compra allí leche, pan, queso y té dulce. '
          'Al final del día es agradable descansar en casa en silencio y ver una película.',
    ),
    PhraseEntry(
      topic: 'Сестра',
      ru: 'Моя сестра любит читать книги в тишине своей уютной комнаты. '
          'После этого моя сестра обычно идет в магазин за свежими продуктами. '
          'Там всегда можно найти большой выбор вкусных фруктов и овощей. '
          'Обычно люди покупают там молоко, хлеб, сыр и сладкий чай. '
          'В конце дня приятно отдохнуть дома в тишине и посмотреть фильм.',
      en: 'My sister likes to read books in the silence of her cozy room. '
          'After that, my sister usually goes to the store for fresh groceries. '
          'There you can always find a large selection of delicious fruits and vegetables. '
          'Usually people buy milk, bread, cheese, and sweet tea there. '
          'At the end of the day, it is nice to relax at home in silence and watch a movie.',
      es: 'A mi hermana le gusta leer libros en el silencio de su habitación acogedora. '
          'Después de eso, mi hermana suele ir a la tienda a buscar productos frescos. '
          'Allí siempre se puede encontrar una gran selección de frutas y verduras deliciosas. '
          'Por lo general, la gente compra allí leche, pan, queso y té dulce. '
          'Al final del día es agradable descansar en casa en silencio y ver una película.',
    ),
    PhraseEntry(
      topic: 'Друг',
      ru: 'Мой друг всегда начинает свой день с энергичной зарядки и душа. '
          'После этого мой друг обычно идет в магазин за свежими продуктами. '
          'Там всегда можно найти большой выбор вкусных фруктов и овощей. '
          'Обычно люди покупают там молоко, хлеб, сыр и сладкий чай. '
          'В конце дня приятно отдохнуть дома в тишине и посмотреть фильм.',
      en: 'My friend always starts his day with an energetic workout and a shower. '
          'After that, my friend usually goes to the store for fresh groceries. '
          'There you can always find a large selection of delicious fruits and vegetables. '
          'Usually people buy milk, bread, cheese, and sweet tea there. '
          'At the end of the day, it is nice to relax at home in silence and watch a movie.',
      es: 'Mi amigo siempre empieza el día con un entrenamiento enérgico y una ducha. '
          'Después de eso, mi amigo suele ir a la tienda a buscar productos frescos. '
          'Allí siempre se puede encontrar una gran selección de frutas y verduras deliciosas. '
          'Por lo general, la gente compra allí leche, pan, queso y té dulce. '
          'Al final del día es agradable descansar en casa en silencio y ver una película.',
    ),
    PhraseEntry(
      topic: 'Виктор',
      ru: 'Виктор интересуется техникой и часто чинит старые компьютеры дома. '
          'После этого Виктор обычно идет в магазин за свежими продуктами. '
          'Там всегда можно найти большой выбор вкусных фруктов и овощей. '
          'Обычно люди покупают там молоко, хлеб, сыр и сладкий чай. '
          'В конце дня приятно отдохнуть дома в тишине и посмотреть фильм.',
      en: 'Victor is interested in technology and often repairs old computers at home. '
          'After that, Victor usually goes to the store for fresh groceries. '
          'There you can always find a large selection of delicious fruits and vegetables. '
          'Usually people buy milk, bread, cheese, and sweet tea there. '
          'At the end of the day, it is nice to relax at home in silence and watch a movie.',
      es: 'Víctor se interesa por la tecnología y a menudo repara ordenadores viejos en casa. '
          'Después de eso, Víctor suele ir a la tienda a buscar productos frescos. '
          'Allí siempre se puede encontrar una gran selección de frutas y verduras deliciosas. '
          'Por lo general, la gente compra allí leche, pan, queso y té dulce. '
          'Al final del día es agradable descansar en casa en silencio y ver una película.',
    ),
    PhraseEntry(
      topic: 'Отец',
      ru: 'Мой отец работает в большой компании и часто ездит на важные встречи. '
          'После этого мой отец обычно идет в магазин за свежими продуктами. '
          'Там всегда можно найти большой выбор вкусных фруктов и овощей. '
          'Обычно люди покупают там молоко, хлеб, сыр и сладкий чай. '
          'В конце дня приятно отдохнуть дома в тишине и посмотреть фильм.',
      en: 'My father works in a large company and often travels to important meetings. '
          'After that, my father usually goes to the store for fresh groceries. '
          'There you can always find a large selection of delicious fruits and vegetables. '
          'Usually people buy milk, bread, cheese, and sweet tea there. '
          'At the end of the day, it is nice to relax at home in silence and watch a movie.',
      es: 'Mi padre trabaja en una gran empresa y a menudo viaja a reuniones importantes. '
          'Después de eso, mi padre suele ir a la tienda a buscar productos frescos. '
          'Allí siempre se puede encontrar una gran selección de frutas y verduras deliciosas. '
          'Por lo general, la gente compra allí leche, pan, queso y té dulce. '
          'Al final del día es agradable descansar en casa en silencio y ver una película.',
    ),
    PhraseEntry(
      topic: 'Мама',
      ru: 'Моя мама каждое утро готовит вкусный завтрак для всей нашей семьи. '
          'После этого моя мама обычно идет в магазин за свежими продуктами. '
          'Там всегда можно найти большой выбор вкусных фруктов и овощей. '
          'Обычно люди покупают там молоко, хлеб, сыр и сладкий чай. '
          'В конце дня приятно отдохнуть дома в тишине и посмотреть фильм.',
      en: 'My mother prepares a delicious breakfast for our whole family every morning. '
          'After that, my mother usually goes to the store for fresh groceries. '
          'There you can always find a large selection of delicious fruits and vegetables. '
          'Usually people buy milk, bread, cheese, and sweet tea there. '
          'At the end of the day, it is nice to relax at home in silence and watch a movie.',
      es: 'Mi madre prepara un desayuno delicioso para toda nuestra familia todas las mañanas. '
          'Después de eso, mi madre suele ir a la tienda a buscar productos frescos. '
          'Allí siempre se puede encontrar una gran selección de frutas y verduras deliciosas. '
          'Por lo general, la gente compra allí leche, pan, queso y té dulce. '
          'Al final del día es agradable descansar en casa en silencio y ver una película.',
    ),
    PhraseEntry(
      topic: 'Ольга',
      ru: 'Ольга работает в красивом цветочном магазине и помогает людям выбирать букеты. '
          'После этого Ольга обычно идет в магазин за свежими продуктами. '
          'Там всегда можно найти большой выбор вкусных фруктов и овощей. '
          'Обычно люди покупают там молоко, хлеб, сыр и сладкий чай. '
          'В конце дня приятно отдохнуть дома в тишине и посмотреть фильм.',
      en: 'Olga works in a beautiful flower shop and helps people choose bouquets. '
          'After that, Olga usually goes to the store for fresh groceries. '
          'There you can always find a large selection of delicious fruits and vegetables. '
          'Usually people buy milk, bread, cheese, and sweet tea there. '
          'At the end of the day, it is nice to relax at home in silence and watch a movie.',
      es: 'Olga trabaja en una hermosa floristería y ayuda a la gente a elegir ramos. '
          'Después de eso, Olga suele ir a la tienda a buscar productos frescos. '
          'Allí siempre se puede encontrar una gran selección de frutas y verduras deliciosas. '
          'Por lo general, la gente compra allí leche, pan, queso y té dulce. '
          'Al final del día es agradable descansar en casa en silencio y ver una película.',
    ),
    PhraseEntry(
      topic: 'Андрей',
      ru: 'Андрей увлекается спортом и каждый вечер ходит на пробежку в парк. '
          'После этого Андрей обычно идет в магазин за свежими продуктами. '
          'Там всегда можно найти большой выбор вкусных фруктов и овощей. '
          'Обычно люди покупают там молоко, хлеб, сыр и сладкий чай. '
          'В конце дня приятно отдохнуть дома в тишине и посмотреть фильм.',
      en: 'Andrey is fond of sports and goes for a run in the park every evening. '
          'After that, Andrey usually goes to the store for fresh groceries. '
          'There you can always find a large selection of delicious fruits and vegetables. '
          'Usually people buy milk, bread, cheese, and sweet tea there. '
          'At the end of the day, it is nice to relax at home in silence and watch a movie.',
      es: 'Andréi es aficionado al deporte y sale a correr al parque todas las tardes. '
          'Después de eso, Andréi suele ir a la tienda a buscar productos frescos. '
          'Allí siempre se puede encontrar una gran selección de frutas y verduras deliciosas. '
          'Por lo general, la gente compra allí leche, pan, queso y té dulce. '
          'Al final del día es agradable descansar en casa en silencio y ver una película.',
    ),
    PhraseEntry(
      topic: 'Брат',
      ru: 'Мой брат обычно просыпается по будильнику и быстро собирается на учебу. '
          'После этого мой брат обычно идет в магазин за свежими продуктами. '
          'Там всегда можно найти большой выбор вкусных фруктов и овощей. '
          'Обычно люди покупают там молоко, хлеб, сыр и сладкий чай. '
          'В конце дня приятно отдохнуть дома в тишине и посмотреть фильм.',
      en: 'My brother usually wakes up to an alarm clock and quickly gets ready for study. '
          'After that, my brother usually goes to the store for fresh groceries. '
          'There you can always find a large selection of delicious fruits and vegetables. '
          'Usually people buy milk, bread, cheese, and sweet tea there. '
          'At the end of the day, it is nice to relax at home in silence and watch a movie.',
      es: 'Mi hermano normalmente se despierta con el despertador y se prepara rápido para estudiar. '
          'Después de eso, mi hermano suele ir a la tienda a buscar productos frescos. '
          'Allí siempre se puede encontrar una gran selección de frutas y verduras deliciosas. '
          'Por lo general, la gente compra allí leche, pan, queso y té dulce. '
          'Al final del día es agradable descansar en casa en silencio y ver una película.',
    ),
    PhraseEntry(
      topic: 'От первого лица',
      ru: 'Каждый день я стараюсь находить время для полезных занятий и отдыха. '
          'После этого я обычно иду в магазин за свежими продуктами. '
          'Там всегда можно найти большой выбор вкусных фруктов и овощей. '
          'Обычно люди покупают там молоко, хлеб, сыр и сладкий чай. '
          'В конце дня приятно отдохнуть дома в тишине и посмотреть фильм.',
      en: 'Every day I try to find time for useful activities and rest. '
          'After that, I usually go to the store for fresh groceries. '
          'There you can always find a large selection of delicious fruits and vegetables. '
          'Usually people buy milk, bread, cheese, and sweet tea there. '
          'At the end of the day, it is nice to relax at home in silence and watch a movie.',
      es: 'Todos los días intento encontrar tiempo para actividades útiles y descanso. '
          'Después de eso, suelo ir a la tienda a buscar productos frescos. '
          'Allí siempre se puede encontrar una gran selección de frutas y verduras deliciosas. '
          'Por lo general, la gente compra allí leche, pan, queso y té dulce. '
          'Al final del día es agradable descansar en casa en silencio y ver una película.',
    ),
  ];

  static int get count => phrases.length;

  /// Случайный индекс фразы, исключая уже использованные в этом матче/
  /// сессии (см. rounds.phrase_index) — чтобы за 10 раундов подряд фразы
  /// не повторялись, пока не исчерпан весь банк. Если банк исчерпан (не
  /// должно происходить при 10 раундах и 10 фразах, но на случай будущего
  /// расширения) — снимает исключение и выбирает из полного списка.
  static int randomIndex({Set<int> exclude = const {}}) {
    final available = [for (var i = 0; i < phrases.length; i++) i]..removeWhere(exclude.contains);
    final pool = available.isEmpty ? List.generate(phrases.length, (i) => i) : available;
    return pool[_random.nextInt(pool.length)];
  }

  static PhraseEntry entry(int index) => phrases[index % phrases.length];

  static String textFor(int index, String languageCode) => entry(index).forLanguage(languageCode);
}
