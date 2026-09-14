import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/game_access.dart';
import '../../core/theme.dart';
import '../../data/library_track.dart';
import '../../data/my_languages.dart';
import '../../data/track_library.dart';
import '../../data/track_transcriber.dart';
import '../../widgets/chrolingo_widgets.dart';

/// Фонотека режима «Аудирование».
///
/// ДВА ИСТОЧНИКА ЗАПИСЕЙ В ОДНОМ СПИСКЕ: те, что пришли с игрой, и те, что
/// добавил сам игрок. Разделять их на два экрана незачем — слушают их
/// одинаково, — но фильтры сверху дают посмотреть на каждый вид отдельно.
///
/// СВОИ ЗАПИСИ СТОЯТ ВЫШЕ. Игрок пришёл сюда за тем, что добавил только
/// что; заставлять его прокручивать чужое ради своего — значит каждый раз
/// брать с него плату за нашу сортировку.
class LibraryScreen extends StatefulWidget {
  const LibraryScreen({super.key});

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

enum _Filter { all, library, uploaded }

class _LibraryScreenState extends State<LibraryScreen> {
  _Filter _filter = _Filter.all;
  List<LibraryTrack> _tracks = const [];
  MyLanguages? _languages;
  WalletState _wallet = WalletState.empty;
  bool _loading = true;

  /// Что сейчас разбирается. Пока идёт разбор, список не трогаем: игрок
  /// должен видеть, что работа идёт, и не начать её второй раз.
  String? _busyTrackId;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final tracks = await TrackLibrary.all();
      final languages = await fetchMyLanguages();
      final wallet = await GameAccess.sync();
      if (!mounted) return;
      setState(() {
        _tracks = tracks;
        _languages = languages;
        _wallet = wallet;
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  List<LibraryTrack> get _shown => switch (_filter) {
        _Filter.all => _tracks,
        _Filter.library => [for (final t in _tracks) if (!t.isUploaded) t],
        _Filter.uploaded => [for (final t in _tracks) if (t.isUploaded) t],
      };

  // -------------------------------------------------------------------
  // Добавление своей записи
  // -------------------------------------------------------------------

  Future<void> _addOwn() async {
    final languages = _languages;
    if (languages == null) {
      _say('Сначала выбери языки в настройках.');
      return;
    }

    final picked = await FilePicker.platform.pickFiles(type: FileType.audio);
    final path = picked?.files.single.path;
    if (path == null || !mounted) return;

    final duration = await _durationOf(path);
    if (!mounted) return;
    if (duration <= 0) {
      _say('Не удалось прочитать длину записи — возможно, формат не поддерживается.');
      return;
    }

    final track = LibraryTrack(
      id: 'own_${DateTime.now().microsecondsSinceEpoch}',
      title: _titleFrom(path),
      artist: '',
      source: TrackSource.uploaded,
      path: path,
      durationMs: duration,
      language: languages.learns,
      translationLanguage: languages.speaks,
      hasSubtitles: false,
      addedAt: DateTime.now(),
    );

    final confirmed = await _confirmCost(track);
    if (confirmed != true || !mounted) return;

    await TrackLibrary.add(track);
    if (!mounted) return;
    setState(() {
      _tracks = [track, ..._tracks];
      _busyTrackId = track.id;
    });
    await _transcribe(track);
  }

  /// Плашка с ценой разбора. ПОКАЗЫВАЕТСЯ ДО ТОГО, как что-то потрачено:
  /// узнать цену после списания — значит не иметь выбора.
  Future<bool?> _confirmCost(LibraryTrack track) {
    final cost = transcriptionEnergyCost(track.durationMs);
    final enough = _wallet.energyCurrent >= cost;
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.navy2,
        title: Text('Разобрать запись',
            style: AppFonts.ui(fontSize: 16, weight: FontWeight.w800)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(track.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: AppFonts.ui(fontSize: 13, weight: FontWeight.w700)),
            const SizedBox(height: 10),
            Text(
              'Длина ${track.lengthLabel} — понадобится $cost '
              '${_energyWord(cost)}.',
              style: const TextStyle(fontSize: 13, height: 1.5),
            ),
            const SizedBox(height: 6),
            Text(
              enough
                  ? 'Сейчас у тебя ${_wallet.energyCurrent} из ${_wallet.energyMax}.'
                  : 'Сейчас у тебя только ${_wallet.energyCurrent} — не хватит.',
              style: TextStyle(
                fontSize: 12,
                color: enough ? AppColors.muted : AppColors.danger,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Отменить')),
          TextButton(
            onPressed: enough ? () => Navigator.pop(ctx, true) : null,
            child: const Text('Подтвердить'),
          ),
        ],
      ),
    );
  }

  Future<void> _transcribe(LibraryTrack track) async {
    try {
      await TrackTranscriber.run(
        track: track,
        translateTo: track.translationLanguage,
      );
      if (!mounted) return;
      _say('Запись разобрана — можно слушать.');
    } catch (e) {
      if (!mounted) return;
      _say('Не получилось: $e');
    } finally {
      if (mounted) setState(() => _busyTrackId = null);
      await _load();
    }
  }

  /// Длина записи. Спрашиваем у плеера: имя файла и размер о ней не говорят
  /// ничего, а цена разбора считается именно по длине.
  Future<int> _durationOf(String path) async {
    final player = AudioPlayer();
    try {
      await player.setSourceDeviceFile(path);
      final duration = await player.getDuration();
      return duration?.inMilliseconds ?? 0;
    } catch (_) {
      return 0;
    } finally {
      await player.dispose();
    }
  }

  static String _titleFrom(String path) {
    final name = path.split(Platform.pathSeparator).last;
    final dot = name.lastIndexOf('.');
    return dot > 0 ? name.substring(0, dot) : name;
  }

  static String _energyWord(int count) {
    final last = count % 10;
    final tens = count % 100;
    if (tens >= 11 && tens <= 14) return 'единиц энергии';
    if (last == 1) return 'единица энергии';
    if (last >= 2 && last <= 4) return 'единицы энергии';
    return 'единиц энергии';
  }

  void _say(String text) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  // -------------------------------------------------------------------

  Future<void> _open(LibraryTrack track) async {
    if (_busyTrackId == track.id) return;
    if (!track.hasSubtitles) {
      _say('Запись ещё не разобрана.');
      return;
    }
    if (await TrackLibrary.missing(track)) {
      if (mounted) _say('Файла больше нет по прежнему пути.');
      return;
    }
    if (!mounted) return;
    await context.push('/listening/${track.id}');
    if (mounted) _load();
  }

  Future<void> _remove(LibraryTrack track) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.navy2,
        title: Text(track.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: AppFonts.ui(fontSize: 15, weight: FontWeight.w700)),
        content: const Text(
          'Убрать из фонотеки? Сам файл останется на телефоне — мы его не '
          'приносили и удалять не станем.',
          style: TextStyle(height: 1.4),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Отмена')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Убрать', style: TextStyle(color: AppColors.danger)),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await TrackLibrary.remove(track.id);
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Аудирование'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 6),
            child: Center(
              child: Text('⚡ ${_wallet.energyCurrent}',
                  style: AppFonts.mono(
                      fontSize: 12, weight: FontWeight.w700, color: AppColors.gold)),
            ),
          ),
          IconButton(
            onPressed: _busyTrackId == null ? _addOwn : null,
            icon: const Icon(Icons.add, color: AppColors.gold),
            tooltip: 'Добавить свою запись',
          ),
        ],
      ),
      body: SafeArea(child: _body()),
    );
  }

  Widget _body() {
    if (_loading) return const Center(child: CircularProgressIndicator());

    final shown = _shown;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 10),
          child: ChTabBar(
            tabs: const ['Все', 'Библиотека', 'Загруженные'],
            selected: _filter.index,
            onChanged: (i) => setState(() => _filter = _Filter.values[i]),
          ),
        ),
        Expanded(
          child: shown.isEmpty
              ? _empty()
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView.builder(
                    padding: const EdgeInsets.fromLTRB(8, 0, 8, 16),
                    itemCount: shown.length,
                    itemBuilder: (context, index) => _TrackRow(
                      position: index + 1,
                      track: shown[index],
                      busy: _busyTrackId == shown[index].id,
                      onTap: () => _open(shown[index]),
                      onLongPress: shown[index].isUploaded
                          ? () => _remove(shown[index])
                          : null,
                    ),
                  ),
                ),
        ),
      ],
    );
  }

  Widget _empty() => Padding(
        padding: const EdgeInsets.all(28),
        child: Center(
          child: Text(
            switch (_filter) {
              _Filter.uploaded =>
                'Своих записей пока нет. Кнопка «+» вверху добавит любую из '
                    'памяти телефона.',
              _Filter.library => 'Записей от игры пока нет.',
              _Filter.all =>
                'Пока пусто. Кнопка «+» вверху добавит запись из памяти '
                    'телефона — её разберёт модель, и можно будет слушать.',
            },
            textAlign: TextAlign.center,
            style: const TextStyle(color: AppColors.muted, fontSize: 13, height: 1.5),
          ),
        ),
      );
}

/// Строка фонотеки: номер, название, исполнитель, длина — как в плеере.
class _TrackRow extends StatelessWidget {
  final int position;
  final LibraryTrack track;
  final bool busy;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  const _TrackRow({
    required this.position,
    required this.track,
    required this.busy,
    required this.onTap,
    required this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final ready = track.hasSubtitles && !busy;
    return InkWell(
      onTap: onTap,
      onLongPress: onLongPress,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 9),
        child: Row(
          children: [
            SizedBox(
              width: 44,
              child: busy
                  ? const Center(
                      child: SizedBox(
                        height: 16,
                        width: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    )
                  : Text('$position',
                      textAlign: TextAlign.center,
                      style: AppFonts.mono(
                          fontSize: 12,
                          weight: FontWeight.w700,
                          color: ready ? AppColors.muted : AppColors.line)),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    track.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppFonts.ui(
                      fontSize: 14,
                      weight: FontWeight.w700,
                      color: ready ? AppColors.cream : AppColors.muted,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    busy
                        ? 'разбираю запись…'
                        : track.hasSubtitles
                            ? (track.artist.isEmpty
                                ? (track.isUploaded ? 'своя запись' : 'из библиотеки')
                                : track.artist)
                            : 'без субтитров',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppFonts.mono(fontSize: 10, color: AppColors.muted),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            Text(track.lengthLabel,
                style: AppFonts.mono(fontSize: 11, color: AppColors.muted)),
          ],
        ),
      ),
    );
  }
}
