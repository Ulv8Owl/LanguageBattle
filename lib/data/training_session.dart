import 'dart:math';

/// Сколько карточек выдаётся за тренировку по умолчанию.
///
/// Колода — сто карточек, но проходить её за раз незачем: двадцать слов
/// это обозримый заход, после которого видно результат, а сотня
/// превращается в марафон, который бросают на середине.
const int defaultTrainingDeckSize = 20;

/// Допустимые размеры тренировки: 10..50 с шагом 10. Совпадают с
/// ограничением на users.training_deck_size (миграция 0022).
const List<int> trainingDeckSizes = [10, 20, 30, 40, 50];

/// Как игрок ответил на карточку.
enum CardOutcome {
  /// Знаю — не переворачивая. Слово закрыто, в этой тренировке не вернётся.
  known,

  /// Перевернул, посмотрел перевод и сказал «знаю». Слово вернётся ещё раз
  /// в самом конце: подсмотренный ответ — это ещё не выученное слово.
  knownAfterFlip,

  /// Не знаю. Вернётся скоро — пока свежо.
  unknown,
}

/// Одна тренировка: очередь карточек и правила их возврата.
///
/// Вынесено из экрана, потому что правила проверяются только прогоном
/// последовательности ответов, а не глазами по одному экрану: «вернётся
/// скоро» и «вернётся в конце» отличаются как раз тем, чего на одном кадре
/// не видно.
class TrainingSession {
  /// Индексы слов колоды, попавшие в эту тренировку, в порядке показа.
  final List<int> _queue;

  /// Слова, которые ещё не закрыты. Тренировка идёт, пока список непуст.
  final Set<int> _open;

  /// Слова, уже побывавшие перевёрнутыми: их «знаю» закрывает сразу, без
  /// второго круга, иначе они возвращались бы бесконечно.
  final Set<int> _seenFlipped = {};

  final Random _random;
  final int _total;

  TrainingSession(List<int> wordIndices, {Random? random})
      : _queue = List.of(wordIndices),
        _open = wordIndices.toSet(),
        _total = wordIndices.length,
        _random = random ?? Random();

  /// Сколько слов в тренировке всего.
  int get total => _total;

  /// Сколько слов уже закрыто. Именно это число идёт в счётчик «21 / 100»,
  /// а не количество показов: одно слово может показаться трижды.
  int get completed => _total - _open.length;

  /// Индекс текущей карточки или null, если тренировка окончена.
  int? get current => _queue.isEmpty ? null : _queue.first;

  bool get isDone => _queue.isEmpty;

  /// Учесть ответ по текущей карточке и перейти к следующей.
  void answer(CardOutcome outcome) {
    if (_queue.isEmpty) return;
    final word = _queue.removeAt(0);

    switch (outcome) {
      case CardOutcome.known:
        _open.remove(word);
      case CardOutcome.knownAfterFlip:
        if (_seenFlipped.contains(word)) {
          // Второй заход уже был — больше не гоняем.
          _open.remove(word);
        } else {
          _seenFlipped.add(word);
          _queue.add(word);
        }
      case CardOutcome.unknown:
        _seenFlipped.add(word);
        _queue.insert(_soonPosition(), word);
    }
  }

  /// Куда вернуть слово, которого игрок не знает.
  ///
  /// Не сразу следующим — иначе ответ виден на предыдущем экране и слово
  /// «вспоминается» само; и не в конец — тогда оно вернётся, когда уже
  /// забудется. Через одну-три карточки: достаточно, чтобы вспоминать
  /// пришлось, и достаточно скоро, чтобы было что вспоминать.
  int _soonPosition() {
    if (_queue.length <= 1) return _queue.length;
    final furthest = min(3, _queue.length);
    return 1 + _random.nextInt(furthest);
  }
}
