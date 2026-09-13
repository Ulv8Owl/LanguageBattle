import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme.dart';
import '../../data/audio_track.dart';
import '../../data/my_languages.dart';
import '../../data/track_captions.dart';
import '../../data/word_dictionary.dart';
import '../../data/youtube_captions.dart';
import '../../widgets/chrolingo_widgets.dart';

/// Инструмент: притянуть к треку субтитры по ссылке на ролик.
///
/// ОТКРЫВАЕТСЯ, ПОКА У ТРЕКА НЕТ СЛОВ. Звук без разметки играть можно, но
/// смотреть в «Аудировании» будет не на что: весь режим — про то, какое
/// слово звучит сейчас. Поэтому выбор трека без субтитров ведёт сюда, и
/// будет вести до тех пор, пока они не появятся.
///
/// ЧТО ИМЕННО ПРИТЯГИВАЕТСЯ. Только текст и время. Звук у трека свой, в
/// самой игре; ролик нужен исключительно как источник пословного тайминга,
/// который автоматические субтитры YouTube отдают в parts.
///
/// КУДА КЛАДЁТСЯ. На это устройство, рядом с треком. В сборку и в
/// репозиторий притянутое не уходит: текст ролика принадлежит его автору.
class CaptionImportScreen extends StatefulWidget {
  final String trackId;

  const CaptionImportScreen({super.key, required this.trackId});

  @override
  State<CaptionImportScreen> createState() => _CaptionImportScreenState();
}

class _CaptionImportScreenState extends State<CaptionImportScreen> {
  final _url = TextEditingController();

  AudioTrack? _track;
  bool _loading = true;
  bool _busy = false;
  String? _error;

  /// Что притянулось — показываем ДО закрепления. Сохранять вслепую значит
  /// узнать о кривых субтитрах уже в режиме.
  List<TrackLine>? _preview;
  bool _wordAccurate = true;
  String _videoTitle = '';
  String _videoId = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _url.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final track = await TrackCatalog.load(widget.trackId);
      if (!mounted) return;
      setState(() {
        _track = track;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  Future<void> _fetch() async {
    final track = _track;
    if (track == null || _busy) return;
    final videoId = YoutubeCaptions.videoIdFrom(_url.text);
    if (videoId == null) {
      setState(() => _error = 'Не разобрал ссылку. Нужна ссылка на ролик YouTube.');
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
      _preview = null;
    });
    try {
      final languages = await fetchMyLanguages();
      final dictionary = languages == null
          ? null
          : await WordDictionary.load(from: track.language, to: languages.speaks);
      final result = await YoutubeCaptions.fetch(
        videoId: videoId,
        language: track.language,
        dictionary: dictionary,
      );
      if (!mounted) return;
      setState(() {
        _preview = result.lines;
        _wordAccurate = result.wordAccurate;
        _videoTitle = result.title;
        _videoId = videoId;
        _busy = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e is CaptionsUnavailable ? '$e' : 'Не получилось: $e';
        _busy = false;
      });
    }
  }

  Future<void> _attach() async {
    final preview = _preview;
    if (preview == null) return;
    setState(() => _busy = true);
    try {
      await TrackCaptions.save(
        trackId: widget.trackId,
        videoId: _videoId,
        lines: preview,
      );
      if (!mounted) return;
      // Возвращаем true — список треков по нему поймёт, что можно играть.
      context.pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Не удалось сохранить: $e';
        _busy = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Субтитры к треку')),
      body: SafeArea(child: _body()),
    );
  }

  Widget _body() {
    if (_loading) return const Center(child: CircularProgressIndicator());

    final track = _track;
    if (track == null) {
      return _note(_error ?? 'Трек не найден');
    }

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        ChPanel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(track.title,
                  style: AppFonts.ui(fontSize: 15, weight: FontWeight.w800)),
              const SizedBox(height: 6),
              Text(
                'У этого трека ещё нет слов. Дай ссылку на ролик с той же '
                'записью — из его субтитров возьмётся текст и время каждого '
                'слова. Сам звук останется тот, что лежит в игре.',
                style: const TextStyle(color: AppColors.muted, fontSize: 12, height: 1.5),
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        TextField(
          controller: _url,
          autocorrect: false,
          keyboardType: TextInputType.url,
          decoration: const InputDecoration(
            labelText: 'Ссылка на ролик',
            hintText: 'https://www.youtube.com/watch?v=…',
          ),
          onSubmitted: (_) => _fetch(),
        ),
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          child: ElevatedButton(
            onPressed: _busy ? null : _fetch,
            child: Text(_busy ? 'Тяну…' : 'Притянуть субтитры'),
          ),
        ),
        if (_error != null) ...[
          const SizedBox(height: 12),
          Text(_error!,
              style: const TextStyle(color: AppColors.danger, fontSize: 12, height: 1.4)),
        ],
        if (_preview != null) ...[
          const SizedBox(height: 18),
          _previewPanel(_preview!),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: _busy ? null : _attach,
              child: const Text('Закрепить за треком'),
            ),
          ),
        ],
      ],
    );
  }

  Widget _previewPanel(List<TrackLine> lines) {
    final words = [for (final line in lines) ...line.words];
    final translated = words.where((w) => w.translation != null).length;
    final last = words.isEmpty ? 0 : words.last.endMs;

    return ChPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(_videoTitle,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: AppFonts.ui(fontSize: 13, weight: FontWeight.w800)),
          const SizedBox(height: 8),
          _row('строк', '${lines.length}'),
          _row('слов', '${words.length}'),
          _row('с переводом', '$translated из ${words.length}'),
          _row('длина', '${(last / 1000).round()} с'),
          const SizedBox(height: 8),
          Text(
            _wordAccurate
                // Ровно то, ради чего инструмент и нужен.
                ? 'Время у каждого слова своё — подсветка пойдёт точно.'
                : 'У этих субтитров время только у строк: внутри строки слова '
                    'поделены поровну, и подсветка будет приблизительной. '
                    'Поищи ролик с автоматическими субтитрами.',
            style: AppFonts.mono(
              fontSize: 9,
              color: _wordAccurate ? AppColors.ok : AppColors.muted,
            ),
          ),
          if (translated < words.length) ...[
            const SizedBox(height: 6),
            Text(
              'Переводы подставлены из банка слов; чего в нём нет, осталось '
              'без перевода.',
              style: AppFonts.mono(fontSize: 9, color: AppColors.muted),
            ),
          ],
        ],
      ),
    );
  }

  Widget _row(String label, String value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          children: [
            Expanded(
              child: Text(label,
                  style: const TextStyle(color: AppColors.muted, fontSize: 12)),
            ),
            Text(value,
                style: AppFonts.mono(
                    fontSize: 11, weight: FontWeight.w700, color: AppColors.gold)),
          ],
        ),
      );

  Widget _note(String text) => Padding(
        padding: const EdgeInsets.all(24),
        child: Center(
          child: Text(text,
              textAlign: TextAlign.center,
              style: const TextStyle(color: AppColors.muted, fontSize: 13, height: 1.4)),
        ),
      );
}
