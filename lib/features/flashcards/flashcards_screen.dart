import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/supabase_client.dart';
import '../../core/theme.dart';
import '../../data/phrase_bank.dart';
import '../../data/phrase_glossary.dart';
import '../../data/player_rating.dart';
import '../../data/remote_content.dart';
import '../../data/training_session.dart';
import '../../widgets/ai_avatar.dart';
import '../../widgets/chrolingo_widgets.dart';
import '../../widgets/speak_button.dart';

/// «Тренировка» — три шага вокруг ОДНОЙ фразы.
///
/// 1. Игрок видит фразу на родном языке и отмечает слова, перевода которых
///    не знает. Не набралось десяти — приходит следующая фраза.
/// 2. Отмеченные слова он проходит карточками.
/// 3. Ту фразу, слова которой он учил, он произносит вслух — раундом,
///    ничем не отличающимся от Одиночной Игры.
///
/// ЧЕМ ЭТО ЛУЧШЕ ПРЕЖНЕЙ ТРЕНИРОВКИ. Раньше это была колода из ста слов,
/// купленных набором в Магазине: слова приходили сами, из списка, никак не
/// связанного с тем, что игрок хотел сказать. Теперь слова выбирает он сам
/// — ровно те, на которых спотыкается, — и учит их не отдельно, а внутри
/// фразы, которую в конце и произносит.
///
/// ЭНЕРГИИ ЭТИ ДВА ШАГА НЕ СТОЯТ и подписки не требуют: ни выбор слов, ни
/// карточки не ходят ни в ASR, ни в LLM. Платным остаётся только третий
/// шаг — там говорит и оценивает уже обычный раунд.
class FlashcardsScreen extends StatefulWidget {
  const FlashcardsScreen({super.key});

  @override
  State<FlashcardsScreen> createState() => _FlashcardsScreenState();
}

/// Шаг тренировки.
enum _Stage { loading, failed, picking, cards, cardsDone }

class _FlashcardsScreenState extends State<FlashcardsScreen> {
  /// Сколько слов надо набрать, чтобы перейти к карточкам.
  ///
  /// Десять — не круглое число ради круглого: заход меньше десяти слов
  /// заканчивается раньше, чем игрок успевает втянуться, а фраза обычно
  /// даёт их две-три, то есть до карточек он доходит за три-четыре фразы и
  /// успевает увидеть разные обороты.
  static const int _minWords = 10;

  _Stage _stage = _Stage.loading;
  String? _error;

  String _nativeLanguage = 'ru';
  String _targetLanguage = 'en';
  int _levelIndex = 0;

  /// Фразы уровня в перемешанном порядке и место в этом порядке.
  List<int> _phraseOrder = const [];
  int _phraseCursor = 0;

  /// Фраза, которая показана сейчас.
  int _phraseIndex = -1;
  List<PhraseElement> _nativeElements = const [];
  String _nativeTail = '';

  /// Слова текущей фразы: по элементам, в порядке показа.
  List<List<GlossedWord>> _wordsByElement = const [];

  /// Что отмечено на ТЕКУЩЕЙ фразе: «элемент.слово».
  final Set<String> _markedHere = {};

  /// Всё отобранное за эту тренировку, в порядке отметок.
  final List<GlossedWord> _picked = [];

  /// Из какой фразы пришло последнее отмеченное слово — её игрок и скажет
  /// в конце (см. _startSpeaking).
  int _lastPickedPhrase = -1;

  /// Карточки: очередь и её правила — общие с прежней Тренировкой.
  TrainingSession? _session;
  bool _flipped = false;
  int _known = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _stage = _Stage.loading);
    try {
      final uid = currentUserId;
      final profile = await supabase
          .from('users')
          .select('native_language')
          .eq('id', uid)
          .maybeSingle();
      final learning = await supabase
          .from('user_languages')
          .select('language_code, native_for, ${PlayerRating.columns}')
          .eq('user_id', uid)
          .eq('role', 'learning')
          .eq('is_active', true)
          .limit(1)
          .maybeSingle();
      // native_for — родной язык ИМЕННО этой пары (миграция 0025): у
      // полиглота она может быть привязана не к главному родному.
      final native = (learning?['native_for'] as String?) ?? profile?['native_language'] as String?;
      final target = learning?['language_code'] as String?;
      if (native == null || target == null) {
        setState(() {
          _stage = _Stage.failed;
          _error = 'Сначала выбери языковую пару в профиле.';
        });
        return;
      }

      // Уровень — по лиге игрока, как и фразы раунда: тренировать слова
      // выше своей лиги значит учить то, что в игре ещё не встретится.
      final level = PlayerRating.fromRow(learning).levelIndex;
      await PhraseBank.loadLevel(level);
      if (!PhraseBank.hasContentFor(level, native, target)) {
        setState(() {
          _stage = _Stage.failed;
          _error = 'Для этой языковой пары фразы ещё не переведены.';
        });
        return;
      }
      await PhraseGlossary.load(level, native, target);

      if (!mounted) return;
      setState(() {
        _nativeLanguage = native;
        _targetLanguage = target;
        _levelIndex = level;
        _phraseOrder = [
          for (var i = 0; i < PhraseBank.perLevel; i++) level * PhraseBank.perLevel + i,
        ]..shuffle();
        _phraseCursor = 0;
      });
      _showPhrase();
    } on ContentUnavailable {
      if (!mounted) return;
      setState(() {
        _stage = _Stage.failed;
        _error = 'Фразы не скачались — проверь связь и зайди ещё раз.';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _stage = _Stage.failed;
        _error = 'Не удалось начать тренировку: $e';
      });
    }
  }

  /// Следующая фраза на разбор. Круг замыкается — лучше повтор, чем экран
  /// без фразы: отмеченные слова из повтора всё равно уже отобраны.
  void _showPhrase() {
    final index = _phraseOrder[_phraseCursor % _phraseOrder.length];
    _phraseCursor++;
    final native = PhraseBank.elementsFor(index, _nativeLanguage);
    final target = PhraseBank.elementsFor(index, _targetLanguage);
    setState(() {
      _phraseIndex = index;
      _nativeElements = native;
      _nativeTail = PhraseBank.entry(index)?.tailFor(_nativeLanguage) ?? '';
      _wordsByElement = [
        for (var i = 0; i < native.length; i++)
          PhraseGlossary.wordsOf(
            level: _levelIndex,
            native: _nativeLanguage,
            target: _targetLanguage,
            phraseInLevel: index % PhraseBank.perLevel,
            elementIndex: i,
            nativeElement: native[i].text,
            targetElement: i < target.length ? target[i].text : native[i].text,
          ),
      ];
      _markedHere.clear();
      _stage = _Stage.picking;
    });
  }

  String _slot(int element, int word) => '$element.$word';

  void _toggleWord(int element, int word) {
    final key = _slot(element, word);
    final picked = _wordsByElement[element][word];
    setState(() {
      if (_markedHere.remove(key)) {
        _picked.removeWhere((w) => w.key == picked.key);
        return;
      }
      _markedHere.add(key);
      // Одно и то же слово в одном значении не берём дважды: во второй
      // фразе оно попалось бы второй карточкой с тем же переводом.
      if (!_picked.any((w) => w.key == picked.key)) _picked.add(picked);
      _lastPickedPhrase = _phraseIndex;
    });
  }

  void _confirm() {
    if (_picked.length < _minWords) return;
    setState(() {
      _session = TrainingSession([for (var i = 0; i < _picked.length; i++) i]);
      _flipped = false;
      _known = 0;
      _stage = _Stage.cards;
    });
  }

  void _answer(bool known) {
    final session = _session;
    if (session == null || session.current == null) return;
    // Подсмотренный ответ — ещё не знание: такая карточка вернётся в конце
    // (см. TrainingSession).
    final outcome = !known
        ? CardOutcome.unknown
        : _flipped
            ? CardOutcome.knownAfterFlip
            : CardOutcome.known;
    setState(() {
      if (known) _known++;
      _flipped = false;
      session.answer(outcome);
      if (session.isDone) _stage = _Stage.cardsDone;
    });
  }

  /// Последний шаг: сказать вслух фразу, слова которой учил.
  ///
  /// ФРАЗА — ТА, ИЗ КОТОРОЙ ПРИШЛО ПОСЛЕДНЕЕ ОТМЕЧЕННОЕ СЛОВО. Фраз за
  /// подбор бывает несколько, а произнести нужно одну; последняя — та,
  /// которую игрок видел только что, и вспоминать её не придётся.
  void _startSpeaking() {
    final index = _lastPickedPhrase >= 0 ? _lastPickedPhrase : _phraseIndex;
    context.pushReplacement('/training?phrase=$index&title=Тренировка');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Тренировка'),
        actions: [
          if (_stage == _Stage.picking || _stage == _Stage.cards)
            Padding(
              padding: const EdgeInsets.only(right: 14),
              child: Center(
                child: Text(
                  _stage == _Stage.picking
                      ? 'Слов: ${_picked.length}'
                      : 'Знаю: $_known из ${_picked.length}',
                  style: AppFonts.mono(fontSize: 11, weight: FontWeight.w700, color: AppColors.gold),
                ),
              ),
            ),
        ],
      ),
      body: SafeArea(child: _body()),
    );
  }

  Widget _body() {
    switch (_stage) {
      case _Stage.loading:
        return const Center(child: CircularProgressIndicator());
      case _Stage.failed:
        return Padding(
          padding: const EdgeInsets.all(24),
          child: Center(
            child: Text(
              _error ?? 'Что-то пошло не так',
              textAlign: TextAlign.center,
              style: const TextStyle(color: AppColors.muted, fontSize: 13, height: 1.4),
            ),
          ),
        );
      case _Stage.picking:
        return _picking();
      case _Stage.cards:
        return _cards();
      case _Stage.cardsDone:
        return _cardsDone();
    }
  }

  // -------------------------------------------------------------------
  // Шаг 1: выбор незнакомых слов
  // -------------------------------------------------------------------

  Widget _picking() {
    final enough = _picked.length >= _minWords;
    return Column(
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
            children: [
              _ChameleonSays(
                level: _levelIndex,
                text: 'Выбери слова, перевод которых ты не знаешь',
              ),
              const SizedBox(height: 10),
              ChPanel(
                child: _PickablePhrase(
                  elements: _nativeElements,
                  tail: _nativeTail,
                  wordsByElement: _wordsByElement,
                  marked: _markedHere,
                  onTap: _toggleWord,
                ),
              ),
              if (_picked.isNotEmpty) ...[
                const SizedBox(height: 14),
                // ВНИЗУ СОБИРАЮТСЯ ОТОБРАННЫЕ СЛОВА — все, а не только с
                // этой фразы: игрок должен видеть, сколько уже набрал и
                // что именно, не листая назад по фразам.
                Wrap(
                  spacing: 7,
                  runSpacing: 7,
                  children: [
                    for (final word in _picked)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
                        decoration: BoxDecoration(
                          border: Border.all(color: AppColors.gold.withValues(alpha: 0.6)),
                          color: AppColors.gold.withValues(alpha: 0.10),
                          borderRadius: BorderRadius.circular(9),
                        ),
                        child: Text(
                          word.word,
                          style: AppFonts.ui(
                              fontSize: 12, weight: FontWeight.w700, color: AppColors.gold),
                        ),
                      ),
                  ],
                ),
              ],
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (!enough)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(
                    'Нужно набрать хотя бы $_minWords слов — '
                    'осталось ${_minWords - _picked.length}',
                    textAlign: TextAlign.center,
                    style: AppFonts.mono(fontSize: 10, color: AppColors.muted),
                  ),
                ),
              // КНОПКА ОДНА И МЕНЯЕТ СМЫСЛ. «Продолжить» — дай ещё фразу,
              // «Подтвердить» — этих слов хватит. Две кнопки рядом
              // заставляли бы выбирать там, где выбора нет: пока слов мало,
              // подтверждать нечего.
              ElevatedButton(
                onPressed: enough ? _confirm : _showPhrase,
                child: Text(enough ? 'ПОДТВЕРДИТЬ' : 'ПРОДОЛЖИТЬ'),
              ),
              if (enough)
                TextButton(
                  onPressed: _showPhrase,
                  child: const Text('Ещё фраза'),
                ),
            ],
          ),
        ),
      ],
    );
  }

  // -------------------------------------------------------------------
  // Шаг 2: карточки
  // -------------------------------------------------------------------

  Widget _cards() {
    final session = _session!;
    final index = session.current;
    if (index == null) return const SizedBox.shrink();
    final word = _picked[index];

    return Column(
      children: [
        Expanded(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: GestureDetector(
                onTap: () => setState(() => _flipped = !_flipped),
                child: ChPanel(
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 28),
                  borderColor: _flipped ? AppColors.gold : null,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        _flipped ? word.translation : word.word,
                        textAlign: TextAlign.center,
                        style: AppFonts.ui(
                          fontSize: 26,
                          weight: FontWeight.w800,
                          color: _flipped ? AppColors.gold : AppColors.cream,
                        ),
                      ),
                      // ДИНАМИК ТОЛЬКО НА ИЗУЧАЕМОЙ СТОРОНЕ. Слушать образец
                      // произношения на родном языке незачем, а перепутать
                      // стороны — значит выдать игроку чужое произношение с
                      // видом образца.
                      if (_flipped) ...[
                        const SizedBox(height: 6),
                        SpeakButton(text: word.translation, languageCode: _targetLanguage),
                      ],
                      const SizedBox(height: 14),
                      Text(
                        // Контекст — тот кусок фразы, из которого слово
                        // взято: у слова в одиночестве смысл часто шире,
                        // чем тот, который игроку нужен.
                        word.context,
                        textAlign: TextAlign.center,
                        style: AppFonts.mono(fontSize: 11, color: AppColors.muted),
                      ),
                      const SizedBox(height: 10),
                      Text(
                        _flipped ? 'нажми, чтобы вернуть слово' : 'нажми, чтобы увидеть перевод',
                        style: AppFonts.mono(fontSize: 9, color: AppColors.muted),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () => _answer(false),
                  child: const Text('Не знаю'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: ElevatedButton(
                  onPressed: () => _answer(true),
                  child: const Text('Знаю'),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _cardsDone() {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.check_circle_outline, size: 52, color: AppColors.ok),
          const SizedBox(height: 14),
          Text('Слова пройдены',
              style: AppFonts.ui(fontSize: 18, weight: FontWeight.w800, color: AppColors.cream)),
          const SizedBox(height: 8),
          const Text(
            'Теперь скажи вслух фразу, слова которой ты только что учил.',
            textAlign: TextAlign.center,
            style: TextStyle(color: AppColors.muted, fontSize: 13, height: 1.4),
          ),
          const SizedBox(height: 22),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: _startSpeaking,
              child: const Text('К ФРАЗЕ'),
            ),
          ),
        ],
      ),
    );
  }
}

/// Реплика хамелеона — та же, что в Одиночной Игре, и по той же причине
/// слева с аватаркой: говорит ИИ, а не игрок.
class _ChameleonSays extends StatelessWidget {
  final int level;
  final String text;

  const _ChameleonSays({required this.level, required this.text});

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const AiAvatar(),
        const SizedBox(width: 8),
        Flexible(
          child: Container(
            padding: const EdgeInsets.all(12),
            decoration: const BoxDecoration(
              color: AppColors.navy3,
              borderRadius: BorderRadius.only(
                topLeft: Radius.circular(4),
                topRight: Radius.circular(14),
                bottomLeft: Radius.circular(14),
                bottomRight: Radius.circular(14),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Уровень ${cefrNames[level]}',
                    style: AppFonts.mono(fontSize: 9, color: AppColors.muted)),
                const SizedBox(height: 5),
                Text(text, style: const TextStyle(color: AppColors.cream, height: 1.4)),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// Названия уровней по индексу лиги — только для подписи над заданием.
const List<String> cefrNames = ['A1', 'A2', 'B1', 'B2', 'C1', 'C2'];

/// Фраза, в которой нажимается КАЖДОЕ СЛОВО ПО ОТДЕЛЬНОСТИ.
///
/// В Одиночной Игре по нажатию переворачивается ЭЛЕМЕНТ — кусок смысла
/// целиком, и там это правильно: подсказка нужна на обороте, а не на
/// слове. Здесь наоборот: игрок отмечает то, чего не знает, а не знать
/// можно «семь», прекрасно зная «в».
class _PickablePhrase extends StatefulWidget {
  final List<PhraseElement> elements;
  final String tail;
  final List<List<GlossedWord>> wordsByElement;

  /// Отмеченные слова текущей фразы: «элемент.слово».
  final Set<String> marked;

  final void Function(int element, int word) onTap;

  const _PickablePhrase({
    required this.elements,
    required this.tail,
    required this.wordsByElement,
    required this.marked,
    required this.onTap,
  });

  @override
  State<_PickablePhrase> createState() => _PickablePhraseState();
}

class _PickablePhraseState extends State<_PickablePhrase> {
  /// Распознаватели живут вместе с виджетом: TextSpan их не освобождает.
  final Map<String, TapGestureRecognizer> _recognizers = {};

  @override
  void dispose() {
    for (final recognizer in _recognizers.values) {
      recognizer.dispose();
    }
    super.dispose();
  }

  TapGestureRecognizer _recognizer(int element, int word) =>
      _recognizers.putIfAbsent('$element.$word',
          () => TapGestureRecognizer()..onTap = () => widget.onTap(element, word));

  @override
  Widget build(BuildContext context) {
    const base = TextStyle(color: AppColors.cream, height: 1.6, fontSize: 16);
    final spans = <TextSpan>[];

    for (var i = 0; i < widget.elements.length; i++) {
      spans.add(TextSpan(text: widget.elements[i].lead, style: base));
      final text = widget.elements[i].text;
      final words = i < widget.wordsByElement.length
          ? widget.wordsByElement[i]
          : const <GlossedWord>[];

      // По тексту элемента идём ровно один раз, вырезая из него слова: так
      // пробелы и запятые ВНУТРИ элемента остаются на своих местах и не
      // становятся частью нажимаемого слова.
      var cursor = 0;
      for (var w = 0; w < words.length; w++) {
        final word = words[w].word;
        final at = text.indexOf(word, cursor);
        if (at < 0) continue;
        if (at > cursor) {
          spans.add(TextSpan(text: text.substring(cursor, at), style: base));
        }
        final marked = widget.marked.contains('$i.$w');
        spans.add(TextSpan(
          text: word,
          style: base.copyWith(
            color: marked ? AppColors.gold : AppColors.cream,
            fontWeight: marked ? FontWeight.w800 : FontWeight.w400,
          ),
          recognizer: _recognizer(i, w),
        ));
        cursor = at + word.length;
      }
      if (cursor < text.length) {
        spans.add(TextSpan(text: text.substring(cursor), style: base));
      }
    }
    spans.add(TextSpan(text: widget.tail, style: base));

    return Text.rich(TextSpan(children: spans));
  }
}
