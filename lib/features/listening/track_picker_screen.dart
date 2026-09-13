import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme.dart';
import '../../data/audio_track.dart';
import '../../data/my_languages.dart';
import '../../data/track_captions.dart';
import '../../widgets/chrolingo_widgets.dart';

/// Выбор трека — первый экран режима.
///
/// ТРЕК БЕЗ СЛОВ ВЕДЁТ НЕ В РЕЖИМ, А В ИНСТРУМЕНТ. Звук без разметки играть
/// можно, но смотреть в «Аудировании» будет не на что; поэтому первый выбор
/// такого трека открывает загрузку субтитров — и будет открывать, пока они
/// не появятся.
///
/// ПОКАЗЫВАЮТСЯ ТОЛЬКО ТРЕКИ, КОТОРЫЕ ИГРОКУ ПОДХОДЯТ: на языке, который он
/// учит, и размеченные на язык, на котором он говорит. Трек, размеченный на
/// испанский, русскоговорящему показывать нечего — верхняя половина экрана
/// осталась бы для него набором незнакомых слов.
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
      final tracks = await TrackCatalog.all();
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
        if (track.language == languages.learns &&
            track.translationLanguage == languages.speaks)
          track,
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
          : 'Для пары ${_languages!.learns} → ${_languages!.speaks} треков пока '
              'нет. Звук кладётся в assets/tracks/, разметка — рядом файлом '
              '<id>.json, и id дописывается в assets/tracks/index.json.');
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
          onReplaceCaptions: () => _replaceCaptions(tracks[index]),
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
  final VoidCallback onReplaceCaptions;

  const _TrackRow({
    required this.track,
    required this.onTap,
    required this.onReplaceCaptions,
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
      // Замена субтитров — редкое действие, и место ему за долгим нажатием,
      // а не отдельной кнопкой в каждой строке списка.
      onLongPress: _ready ? onReplaceCaptions : null,
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
