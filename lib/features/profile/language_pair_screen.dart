import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/all_languages.dart';
import '../../core/nav_state.dart';
import '../../core/supabase_client.dart';
import '../../data/content_languages.dart';
import '../../data/native_languages.dart';

/// Добавление ещё одной языковой пары (до 4 на аккаунт).
///
/// Изучаемый язык всегда выбирается здесь. Родной — только когда у игрока
/// зарегистрирован больше одного (миграция 0025, «Родные языки» в
/// Настройках): полиглот может учить японский именно от китайского, а не
/// от главного родного из профиля, и тогда выбор родного должен быть
/// частью этой формы, а не молчаливым допущением. Если родной один —
/// выбирать нечего, и поле не показывается вовсе.
///
/// Добавление НЕ переключает активную пару и не трогает её рейтинг —
/// новая пара стартует с рейтинга 600 (elo_default_rating, середина Олова)
/// и ждёт, пока её явно выберут активной (тап по плашке на Профиле).
class LanguagePairScreen extends StatefulWidget {
  const LanguagePairScreen({super.key});

  @override
  State<LanguagePairScreen> createState() => _LanguagePairScreenState();
}

class _LanguagePairScreenState extends State<LanguagePairScreen> {
  bool _loading = true;
  bool _saving = false;
  String? _error;
  List<NativeLanguage> _natives = [];

  /// Языки с готовым банком фраз и слов — только их можно взять целевыми.
  /// Реестр знает 32 языка, но учить можно лишь то, что переведено.
  Set<String> _ready = {};

  /// Уже заведённые пары как «родной-изучаемый».
  ///
  /// Раньше здесь лежали одни изучаемые языки, и это повторяло ошибку
  /// сервера: испанский, взятый от русского, закрывал испанский от
  /// английского — то есть ровно ту вторую пару, ради которой заводят
  /// второй родной язык.
  Set<String> _usedPairs = {};
  String? _selectedTarget;
  String? _selectedNative;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final uid = currentUserId;
      final natives = await NativeLanguages.fetch(uid);
      final ready = await ContentLanguages.ready();
      final pairs = await supabase
          .from('user_languages')
          .select('language_code, native_for')
          .eq('user_id', uid)
          .eq('role', 'learning');
      final primary = natives.firstWhere(
        (n) => n.isPrimary,
        orElse: () => natives.isEmpty ? const NativeLanguage(code: 'ru', isPrimary: true) : natives.first,
      );
      final used = pairs
          .map((r) => '${r['native_for'] ?? primary.code}-${r['language_code']}')
          .toSet();
      // Родной по умолчанию — тот, у которого ещё есть что учить. Иначе
      // экран открывался бы на языке без свободных пар и выглядел бы как
      // «добавлять больше нечего», хотя у соседнего родного всё свободно.
      final startNative = natives
              .map((n) => n.code)
              .where((n) => _freeTargetsFor(n, ready, used).isNotEmpty)
              .firstOrNull ??
          primary.code;
      if (!mounted) return;
      setState(() {
        _natives = natives;
        _ready = ready;
        _selectedNative = startNative;
        _usedPairs = used;
        final free = _freeTargetsFor(startNative, ready, used);
        _selectedTarget = free.isEmpty ? null : free.first;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Не удалось загрузить: $e';
      });
    }
  }

  Future<void> _save() async {
    final target = _selectedTarget;
    final native = _selectedNative;
    if (target == null || native == null) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await supabase.rpc('add_language_pair', params: {
        'p_target_language': target,
        'p_native_language': native,
      });
      notifyLanguagePairChanged();
      if (!mounted) return;
      if (context.canPop()) context.pop();
    } catch (e) {
      if (mounted) setState(() => _error = _reasonFor(e));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// Человеческая причина отказа вместо сырого текста исключения.
  ///
  /// ЕДИНСТВЕННЫЙ ЗАПРЕТ НА ИЗУЧАЕМЫЙ ЯЗЫК — совпадение с родным ЭТОЙ ЖЕ
  /// пары. Язык, который стоит у игрока в родных, изучаемым в другой паре
  /// быть может: полиглот с русским и английским в родных вправе учить
  /// английский от русского. Запрещено только ru-ru.
  static String _reasonFor(Object e) {
    final text = e.toString();
    if (text.contains('target_equals_native')) {
      return 'Нельзя учить язык у самого себя — выбери другой изучаемый '
          'или другой родной.';
    }
    if (text.contains('pair_already_exists')) return 'Такая пара уже есть.';
    if (text.contains('pair_limit_reached')) return 'Больше четырёх пар не бывает.';
    if (text.contains('native_not_registered')) {
      return 'Этот родной язык ещё не добавлен в настройках.';
    }
    return 'Не удалось добавить пару: $e';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Новая языковая пара')),
      body: SafeArea(
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : Padding(
                padding: const EdgeInsets.all(20),
                child: _buildBody(),
              ),
      ),
    );
  }

  /// Что ещё можно учить с этого родного языка.
  ///
  /// Статический, потому что нужен до setState — на загрузке, когда полей
  /// экрана ещё нет, а решить, с какого родного открыться, уже надо.
  ///
  /// Сортировка обязательна: [ready] — множество, и «первый» элемент без
  /// неё зависит от порядка обхода, то есть предложенный по умолчанию
  /// язык менялся бы от запуска к запуску.
  static List<String> _freeTargetsFor(
    String native,
    Set<String> ready,
    Set<String> usedPairs,
  ) =>
      (ready.where((l) => l != native && !usedPairs.contains('$native-$l')).toList())
        ..sort((a, b) => languageName(a).compareTo(languageName(b)));

  List<String> get _availableTargets =>
      _freeTargetsFor(_selectedNative ?? '', _ready, _usedPairs);

  /// Есть ли вообще что добавлять — хоть с одного родного языка.
  ///
  /// Именно ХОТЬ С ОДНОГО. Раньше пустое состояние считалось по текущему
  /// выбранному родному и обрывало всю форму целиком — вместе с выбором
  /// родного. Игрок с парами en-ru и en-es видел «языков больше нет» и не
  /// мог даже переключиться на русский, где свободны и английский, и
  /// испанский. Экран сам себя запирал.
  bool get _anythingToAdd => _natives
      .any((n) => _freeTargetsFor(n.code, _ready, _usedPairs).isNotEmpty);

  Widget _buildBody() {
    final available = _availableTargets;

    if (!_anythingToAdd) {
      return Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.language, size: 48, color: Colors.white38),
          const SizedBox(height: 16),
          const Text(
            'Языки, для которых уже готов банк фраз и слов, добавлены как пары. '
            'Остальные из списка появятся, когда для них будет готов контент.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white70),
          ),
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Выбор родного языка — только когда их несколько; при одном это
        // было бы полем без выбора, то есть шумом.
        if (_natives.length > 1) ...[
          const Text('С какого родного языка учить', style: TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          DropdownButtonFormField<String>(
            initialValue: _selectedNative,
            items: _natives
                .map((n) => DropdownMenuItem(
                      value: n.code,
                      child: Text('${languageFlag(n.code)}  ${languageName(n.code)}'),
                    ))
                .toList(),
            onChanged: (v) => setState(() {
              _selectedNative = v;
              // Смена родного меняет допустимые изучаемые (нельзя учить
              // язык от самого себя) — если прежний выбор стал недопустим,
              // явно пересчитываем его здесь же, а не полагаемся на билд:
              // DropdownButtonFormField падает с ассертом, если его
              // текущее значение не входит в список items.
              if (!_availableTargets.contains(_selectedTarget)) {
                _selectedTarget = _availableTargets.isEmpty ? null : _availableTargets.first;
              }
            }),
          ),
          const SizedBox(height: 20),
        ] else
          Text(
            'Родной язык: ${languageName(_selectedNative)}',
            style: const TextStyle(color: Colors.white54, fontSize: 13),
          ),
        const SizedBox(height: 20),
        const Text('Новый изучаемый язык', style: TextStyle(fontWeight: FontWeight.w700)),
        const SizedBox(height: 8),
        // Свободных языков нет ИМЕННО У ЭТОГО родного — но у другого они
        // есть, иначе мы бы сюда не дошли. Говорим об этом прямо и
        // оставляем выбор родного доступным, вместо того чтобы обрывать
        // форму: именно так экран и запирал сам себя.
        if (available.isEmpty)
          const Text(
            'С этого родного языка уже заведены все доступные пары. '
            'Выберите другой родной язык выше.',
            style: TextStyle(color: Colors.white54, fontSize: 13, height: 1.4),
          )
        else
          DropdownButtonFormField<String>(
            initialValue: _selectedTarget,
            items: available
                .map((l) => DropdownMenuItem(
                      value: l,
                      child: Text('${languageFlag(l)}  ${languageName(l)}'),
                    ))
                .toList(),
            onChanged: (v) => setState(() => _selectedTarget = v),
          ),
        if (_error != null) ...[
          const SizedBox(height: 12),
          Text(_error!, style: const TextStyle(color: Colors.redAccent)),
        ],
        const SizedBox(height: 12),
        const Text(
          'Новая пара стартует с начального рейтинга и не заменяет текущую активную — '
          'переключиться на неё можно будет тапом по плашке в профиле. '
          'Уже заведённые пары не меняются: список родных языков на них не влияет.',
          style: TextStyle(color: Colors.white54, fontSize: 12, height: 1.4),
        ),
        const SizedBox(height: 24),
        ElevatedButton(
          onPressed: _saving || _selectedTarget == null ? null : _save,
          child: _saving
              ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2))
              : const Text('Добавить'),
        ),
      ],
    );
  }
}
