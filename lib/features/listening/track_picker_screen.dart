import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme.dart';
import '../../data/audio_track.dart';
import '../../data/my_languages.dart';
import '../../data/track_captions.dart';
import '../../data/track_glossary.dart';
import '../../widgets/chrolingo_widgets.dart';

/// Выбор трека — первый экран режима.
///
/// ТРЕК БЕЗ СЛОВ ВЕДЁТ НЕ В РЕЖИМ, А В ИНСТРУМЕНТ. Звук без разметки играть
/// можно, но смотреть в «Аудировании» будет не на что; поэтому первый выбор
/// такого трека открывает загрузку субтитров — и будет открывать, пока они
/// не появятся.
///
/// ОТБОР ИДЁТ ПО ОДНОМУ ЯЗЫКУ — ИЗУЧАЕМОМУ. Английская запись нужна каждому,
/// кто учит английский, независимо от того, на каком языке он говорит сам.
/// Раньше трек требовал совпадения ещё и по языку переводов, то есть
/// английская лекция пряталась от испанца просто потому, что разметку
/// писали на русский, — а перевод это свойство ИГРОКА, а не записи: он
/// подставляется на его родной язык (см. TrackCatalog.load).
class TrackPickerScreen extends StatefulWidget {
  const TrackPickerScreen({super.key});

  @override
  State<TrackPickerScreen> createState() => _TrackPickerScreenState();
}

class _TrackPickerScreenState extends State<TrackPickerScreen> {
  List<AudioTrack> _tracks = const [];
  MyLanguages? _languages;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final languages = await fetchMyLanguages();
      final tracks = await TrackCatalog.all(translateTo: languages?.speaks);
      if (!mounted) return;
      setState(() {
        _languages = languages;
        _tracks = tracks;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Не удалось загрузить список: $e';
        _loading = false;
      });
    }
  }

  List<AudioTrack> get _mine {
    final languages = _languages;
    if (languages == null) return const [];
    return [
      for (final track in _tracks)
        if (track.language == languages.learns) track,
    ];
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Аудирование')),
      body: SafeArea(child: _body()),
    );
  }

  Widget _body() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) return _note(_error!);

    final tracks = _mine;
    if (tracks.isEmpty) {
      return _note(_languages == null
          ? 'Сначала выбери языки в настройках.'
          : 'Записей на языке «${_languages!.learns}» пока нет. Звук кладётся '
              'в assets/tracks/, рядом файл <id>.json с языком записи, и id '
              'дописывается в assets/tracks/index.json.');
    }

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.separated(
        padding: const EdgeInsets.all(16),
        itemCount: tracks.length,
        separatorBuilder: (_, _) => const SizedBox(height: 10),
          itemBuilder: (context, index) => _TrackRow(
          track: tracks[index],
          onTap: () => _open(tracks[index]),
          onMenu: () => _menu(tracks[index]),
        ),
      ),
    );
  }

  /// Открыть трек. Со словами — сразу в режим, без слов — в инструмент, и
  /// уже оттуда в режим, если субтитры притянулись.
  Future<void> _open(AudioTrack track) async {
    final ready = track.lines.isNotEmpty;
    if (!ready) {
      final attached = await context.push<bool>('/listening/${track.id}/captions');
      if (attached != true) {
        // Инструмент закрыли, ничего не притянув: играть по-прежнему нечего.
        if (mounted) await _load();
        return;
      }
      if (!mounted) return;
      await _load();
    }
    if (!mounted) return;
    await context.push('/listening/${track.id}');
  }

  /// Что можно сделать с уже готовым треком. Оба действия редкие, поэтому
  /// живут за долгим нажатием, а не кнопками в каждой строке списка.
  Future<void> _menu(AudioTrack track) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: AppColors.navy2,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 12),
            Text(track.title, style: AppFonts.ui(fontSize: 15, weight: FontWeight.w700)),
            const SizedBox(height: 12),
            ListTile(
              leading: const Icon(Icons.translate, color: AppColors.gold),
              title: const Text('Выгрузить слова для перевода'),
              subtitle: const Text(
                'Файл со всеми словами по порядку — останется вписать переводы',
                style: TextStyle(color: AppColors.muted, fontSize: 11),
              ),
              isThreeLine: true,
              onTap: () => Navigator.pop(ctx, 'glossary'),
            ),
            ListTile(
              leading: const Icon(Icons.link_off, color: AppColors.danger),
              title: const Text('Заменить субтитры'),
              onTap: () => Navigator.pop(ctx, 'captions'),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (!mounted) return;
    if (action == 'glossary') await _exportGlossary(track);
    if (action == 'captions') await _replaceCaptions(track);
  }

  /// Заготовка словаря: слова по порядку, переводы пустые.
  ///
  /// ВЫГРУЖАЕТСЯ ИЗ ПРИЛОЖЕНИЯ, А НЕ ПИШЕТСЯ РУКАМИ. Слова берутся из тех
  /// субтитров, которые к треку уже притянуты, — переписывать их заново
  /// значило бы наверняка сбить порядок, а по порядку они и сопоставляются.
  ///
  /// Кладём и в файл, и в буфер обмена: достать файл из памяти приложения
  /// на телефоне неудобно, а вставить текст — одно движение.
  Future<void> _exportGlossary(AudioTrack track) async {
    try {
      final text = TrackGlossary.template(
        track.id,
        [for (final word in track.words) word.text],
      );
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/${track.id}.words.txt');
      await file.writeAsString(text);
      await Clipboard.setData(ClipboardData(text: text));
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('${track.words.length} слов — в буфере и в ${file.path}'),
      ));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Не удалось выгрузить: $e')),
      );
    }
  }

  /// Подставить другую ссылку: притянутые субтитры могут оказаться не от
  /// той записи, и заменить их должно быть можно, не переустанавливая игру.
  Future<void> _replaceCaptions(AudioTrack track) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.navy2,
        title: Text(track.title),
        content: const Text(
          'Забыть притянутые субтитры и подставить другую ссылку?',
          style: TextStyle(height: 1.4),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Отмена')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Заменить', style: TextStyle(color: AppColors.danger)),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await TrackCaptions.clear(track.id);
    if (!mounted) return;
    await _load();
  }

  Widget _note(String text) => Padding(
        padding: const EdgeInsets.all(24),
        child: Center(
          child: Text(
            text,
            textAlign: TextAlign.center,
            style: const TextStyle(color: AppColors.muted, fontSize: 13, height: 1.5),
          ),
        ),
      );
}

class _TrackRow extends StatelessWidget {
  final AudioTrack track;
  final VoidCallback onTap;
  final VoidCallback onMenu;

  const _TrackRow({
    required this.track,
    required this.onTap,
    required this.onMenu,
  });

  bool get _ready => track.lines.isNotEmpty;

  String get _length {
    final seconds = track.durationMs ~/ 1000;
    return '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: onTap,
      // Выгрузка словаря и замена субтитров — редкие действия, и место им
      // за долгим нажатием, а не кнопками в каждой строке списка.
      onLongPress: _ready ? onMenu : null,
      child: ChPanel(
        child: Row(
          children: [
            Icon(_ready ? Icons.hearing : Icons.link_off,
                color: _ready ? AppColors.gold : AppColors.muted),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(track.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppFonts.ui(fontSize: 14, weight: FontWeight.w800)),
                  const SizedBox(height: 2),
                  Text(
                    _ready
                        ? (track.author.isEmpty ? _length : '${track.author} · $_length')
                        : 'нет субтитров — нажми, чтобы добавить',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppFonts.mono(fontSize: 10, color: AppColors.muted),
                  ),
                ],
              ),
            ),
            const Icon(Icons.chevron_right, color: AppColors.muted),
          ],
        ),
      ),
    );
  }
}
