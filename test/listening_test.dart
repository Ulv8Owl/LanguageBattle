import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:language_battle/core/track_clock.dart';
import 'package:language_battle/data/library_track.dart';
import 'package:language_battle/data/track_subtitles.dart';

/// «Аудирование»: фонотека, разбор записи и две строки на экране.
void main() {
  group('цена разбора', () {
    test('одна единица за каждые начатые полминуты', () {
      // Цена обязана расти вместе с длиной: модель берёт деньги за неё.
      expect(transcriptionEnergyCost(0), 1, reason: 'пустая — всё равно попытка');
      expect(transcriptionEnergyCost(1), 1);
      expect(transcriptionEnergyCost(30000), 1);
      expect(transcriptionEnergyCost(30001), 2, reason: 'начатые, а не полные');
      expect(transcriptionEnergyCost(180000), 6, reason: 'три минуты');
    });

    test('формула совпадает с серверной', () {
      // Дублирование вынужденное: клиент цену показывает, сервер списывает.
      // Разойдясь, они покажут одну, а возьмут другую.
      final server = File('supabase/functions/transcribe-track/index.ts')
          .readAsStringSync();
      expect(server, contains('Math.ceil(durationMs / 30_000)'));
      expect(server, contains('Math.max(1,'));
    });
  });

  group('разбор приводится в порядок', () {
    TrackSubtitles subs(List<List<SubtitleWord>> lines) => TrackSubtitles(
          language: 'en',
          translationLanguage: 'ru',
          lines: [for (final l in lines) SubtitleLine(l)],
        );

    SubtitleWord w(String text, int start, int end) =>
        SubtitleWord(text: text, translation: 'п', startMs: start, endMs: end);

    test('перекрытие соседей разводится', () {
      // Поиск активного слова двоичный и на неотсортированном списке молча
      // врёт — дешевле починить один раз здесь.
      final out = subs([
        [w('one', 0, 500), w('two', 300, 900)],
      ]).normalized();
      final words = out.words;
      expect(words[1].startMs, greaterThanOrEqualTo(words[0].endMs));
    });

    test('нулевая длина получает ненулевую', () {
      final out = subs([
        [w('one', 100, 100)],
      ]).normalized();
      expect(out.words.single.endMs, greaterThan(out.words.single.startMs));
    });

    test('пустые слова и пустые строки выбрасываются', () {
      final out = subs([
        [w('', 0, 100)],
        [w('two', 200, 400)],
      ]).normalized();
      expect(out.lines.length, 1);
      expect(out.words.single.text, 'two');
    });
  });

  group('активный элемент', () {
    final starts = [0, 500, 1200];

    test('до первого активного нет', () {
      expect(activeIndex(starts, -1), -1);
    });

    test('держится в паузе до следующего', () {
      // Гасить подсветку на каждый вдох значит мигать ею всю дорогу.
      expect(activeIndex(starts, 700), 1);
      expect(activeIndex(starts, 1199), 1);
      expect(activeIndex(starts, 1200), 2);
    });

    test('пустой список не роняет поиск', () {
      expect(activeIndex(const [], 100), -1);
    });
  });

  group('запись игрока', () {
    test('читается из списка со всем, что о ней известно', () {
      final track = LibraryTrack.fromJson({
        'id': 'x',
        'title': 'Моя запись',
        'source': 'uploaded',
        'path': '/data/user/0/app/files/tracks/x.mp3',
        'duration': 61000,
        'language': 'en',
        'translation': 'ru',
        'subtitles': false,
      });
      expect(track.isUploaded, isTrue);
      expect(track.lengthLabel, '1:01');
      expect(track.hasSubtitles, isFalse);
    });

    test('разбор помечает запись готовой, не трогая путь', () {
      final track = LibraryTrack.fromJson({
        'id': 'x',
        'source': 'uploaded',
        'path': '/a/b.mp3',
        'duration': 1000,
      });
      final done = track.copyWith(hasSubtitles: true, language: 'pl');
      expect(done.hasSubtitles, isTrue);
      expect(done.language, 'pl');
      expect(done.path, '/a/b.mp3');
    });

    test('файл перекладывается к себе, а не остаётся в кеше плагина', () {
      // Выбор файла на Android отдаёт не исходник, а СВОЮ копию в кеше
      // приложения (FileUtils.openFileStream в file_picker). Кеш система
      // чистит когда захочет — и запись, разобранная за энергию игрока,
      // однажды отвечала бы «файла больше нет», хотя он её не трогал.
      final source = File('lib/data/track_library.dart').readAsStringSync();
      expect(source, contains('static Future<String> adopt('));
      expect(source, contains('getApplicationSupportDirectory()'));
      expect(source, contains('.copy(target.path)'));

      // И экран обязан звать это, а не класть в список путь от плагина.
      final screen =
          File('lib/features/listening/library_screen.dart').readAsStringSync();
      expect(screen, contains('TrackLibrary.adopt(path, id)'));
    });

    test('убирая запись, удаляем только СВОЮ копию', () {
      // Путь мог остаться от прежних версий и вести куда угодно в телефоне.
      // Удалить по нему — значит стереть у игрока его собственный файл.
      final source = File('lib/data/track_library.dart').readAsStringSync();
      expect(source, contains('final ours = (await _audioDir()).path;'));
      expect(source, contains('copy.parent.path == ours'));
    });

    test('повторить разбор можно, не добавляя запись заново', () {
      // Иначе запись, на которой разбор сорвался, остаётся в фонотеке
      // навсегда: по нажатию «ещё не разобрана», и всё.
      final screen =
          File('lib/features/listening/library_screen.dart').readAsStringSync();
      expect(screen, contains('Future<void> _retry(LibraryTrack track)'));
      expect(screen, contains('await _retry(track)'));
      // И плата берётся снова — плашка про это говорит прямо.
      final retry = screen.substring(screen.indexOf('Future<void> _retry('));
      expect(retry, contains('_confirmCost(track)'));
    });

    test('длина спрашивается дважды: сразу и по событию', () {
      // Сразу после setSource часть форматов длину ещё не отдаёт, и один
      // вопрос отправлял исправную запись в «формат не поддерживается».
      final screen =
          File('lib/features/listening/library_screen.dart').readAsStringSync();
      expect(screen, contains('player.onDurationChanged'));
      expect(screen, contains('onTimeout: () => Duration.zero'));
    });

    test('_load не трогает экран, которого уже нет', () {
      // Разбор идёт минуты, и _load зовётся из его finally. Незащищённый
      // setState падал исключением поверх уже готового разбора.
      final screen =
          File('lib/features/listening/library_screen.dart').readAsStringSync();
      final load = screen.substring(screen.indexOf('Future<void> _load() async {'));
      expect(
        load.indexOf('if (!mounted) return;'),
        lessThan(load.indexOf('setState(() => _loading = true)')),
      );
    });
  });

  group('запись из библиотеки', () {
    test('путь ассета срезается для плеера', () {
      // Плеер подставляет папку assets сам, и AssetSource('assets/…') ищет
      // assets/assets/… . В индексе путь пишется как везде в проекте — от
      // корня репозитория, — а срезается в одном месте.
      final track = LibraryTrack.fromJson({
        'id': 'p',
        'source': 'library',
        'path': 'assets/tracks/song.mp3',
      });
      expect(track.assetPath, 'tracks/song.mp3');
      expect(
        File('lib/features/listening/player_screen.dart').readAsStringSync(),
        contains('AssetSource(track.assetPath)'),
      );
    });
  });

  group('экран прослушивания', () {
    String player() =>
        File('lib/features/listening/player_screen.dart').readAsStringSync();

    test('звук ждёт поворота, а не играет под плашкой', () {
      // Запись начиналась сразу при входе: пока игрок поворачивал телефон,
      // первые секунды проходили мимо него.
      final s = player();
      expect(s, contains('await _player.setSource('));
      expect(s.contains('_player.play('), isFalse,
          reason: 'пуск — дело _applyOrientation, а не загрузки');
      expect(s, contains('Future<void> _applyOrientation() async'));
    });

    test('поворот обратно ставит на паузу, а своя пауза так и остаётся', () {
      final s = player();
      expect(s, contains('_pausedByRotation'));
      // Пауза, поставленная руками, поворотом не снимается.
      final toggle = s.substring(s.indexOf('Future<void> _togglePlay() async'));
      expect(toggle, contains('_pausedByRotation = false'));
    });

    test('экран не гаснет, пока идут строки', () {
      // Читают их, ничего не нажимая, и телефон считает это бездействием.
      final s = player();
      expect(s, contains('WakelockPlus.enable()'));
      expect(s, contains('WakelockPlus.disable()'));
      expect(
        File('pubspec.yaml').readAsStringSync(),
        contains('wakelock_plus:'),
      );
    });
  });

  group('вызов модели', () {
    String fn() =>
        File('supabase/functions/transcribe-track/index.ts').readAsStringSync();

    test('форма вызова — общая с судьёй, а не своя', () {
      // Здесь стоял вызов по СВОЕЙ схеме DashScope с X-DashScope-SSE:
      // disable. Это форма другого семейства моделей (qwen-audio-3.0-*), а
      // qwen3-omni-flash живёт в совместимом режиме, где поток обязателен.
      // Ровно от этой путаницы _shared/asr.ts и защищается.
      final s = fn();
      expect(s, contains('requestQwen('));
      // Своего похода к провайдеру здесь больше нет вовсе — и это главное:
      // вторая копия вызова означала бы, что следующую особенность
      // провайдера чинят в двух местах, а замечают в одном. (Старую форму
      // проверяем по коду, а не по тексту: в шапке файла она описана
      // словами, и запрет на упоминание запретил бы объяснение.)
      expect(s.contains('await fetch('), isFalse);
      expect(s.contains('"X-DashScope-SSE": "disable"'), isFalse);
      // Аудио едет ссылкой: вложение на запись в минуты не влезет.
      expect(s, contains('input_audio: { data: job.audioUrl }'));
      expect(s, contains('audio: true, temperature: 0, timeoutMs:'));
      // А поток включает общий транспорт — он же один на весь проект.
      expect(
        File('supabase/functions/_shared/review.ts').readAsStringSync(),
        contains('opts.timeoutMs ?? TIMEOUT_MS'),
      );
    });

    test('у разбора свой бюджет, не судейский', () {
      // Судья разбирает одну фразу, здесь модель слушает запись целиком.
      // Один секрет на двоих — это ручка, которая чинит одно и ломает
      // другое молча.
      final s = fn();
      expect(s, contains('TRANSCRIBE_TIMEOUT_MS'));
      expect(s.contains('Deno.env.get("OMNI_TIMEOUT_MS")'), isFalse);
      // И потолок длины тоже свой, потому что провайдерский мы не мерили.
      expect(s, contains('TRANSCRIBE_MAX_MINUTES'));
    });
  });

  group('ответ модели разбирается, каким бы он ни пришёл', () {
    // ФОРМАТ ЗАДАН В ЗАПРОСЕ, НО ЗАДАН — НЕ ЗНАЧИТ СОБЛЮДЁН. Живой разбор
    // вернул строки на уровень вложеннее просимого, приложение упало на
    // приведении типа, и уже оплаченный разбор пропал целиком. К моменту
    // разбора ответа энергия списана, поэтому отвергать ответ из-за лишней
    // пары скобок — значит брать деньги и выбрасывать товар.
    List<List<Map<String, dynamic>>> shape(TrackSubtitles subs) => [
          for (final line in subs.lines)
            [for (final w in line.words) w.toJson()],
        ];

    TrackSubtitles parse(dynamic lines) =>
        TrackSubtitles.fromJson({'language': 'en', 'translation': 'ru', 'lines': lines});

    const word = {'w': 'one', 't': 'раз', 'start': 0, 'end': 100};
    const other = {'w': 'two', 't': 'два', 'start': 200, 'end': 300};

    test('канон — как просили', () {
      final out = parse([
        [word, other],
      ]);
      expect(shape(out).length, 1);
      expect(out.words.length, 2);
    });

    test('лишний уровень вложенности — тот самый живой случай', () {
      // lines: [[[…], […]]] вместо lines: [[…], […]]
      final out = parse([
        [
          [word],
          [other],
        ],
      ]);
      expect(out.lines.length, 2, reason: 'две строки, а не падение');
      expect(out.words.map((w) => w.text), ['one', 'two']);
    });

    test('слова без строк вовсе', () {
      final out = parse([word, other]);
      expect(out.words.length, 2);
    });

    test('строка объектом со списком внутри', () {
      final out = parse([
        {
          'words': [word, other],
        },
      ]);
      expect(out.words.length, 2);
    });

    test('мусор не роняет разбор, а выбрасывается', () {
      final out = parse([
        'строка вместо слова',
        [word],
        null,
        42,
      ]);
      expect(out.words.map((w) => w.text), ['one']);
    });

    test('другие имена полей и время строкой', () {
      final out = parse([
        [
          {'word': 'three', 'translation': 'три', 'begin': '400', 'to': '500'},
        ],
      ]);
      final w = out.words.single;
      expect(w.text, 'three');
      expect(w.translation, 'три');
      expect(w.startMs, 400);
      expect(w.endMs, 500);
    });

    test('разбор идёт в фоне, а не в открытом запросе', () {
      // Edge Function живёт ограниченное время, и когда оно наступает,
      // запрос обрывает ШЛЮЗ — минуя любые catch и finally. Приложение
      // получало голый «сервер ответил 504»: без причины, без подробностей
      // и с уже списанной энергией. Разбор записи в минуты в такой срок не
      // помещается в принципе, поэтому ответ — подтверждение приёма, а
      // результат забирается из хранилища.
      final fn = File('supabase/functions/transcribe-track/index.ts')
          .readAsStringSync();
      expect(fn, contains('EdgeRuntime.waitUntil(work)'));
      expect(fn, contains('accepted: true'));
      expect(fn, contains('202,'));
      // Наш срок обязан быть МЕНЬШЕ платформенного — иначе он не наступает
      // никогда. У боевого воркера тот же урок и бюджет 125 с.
      final ours = RegExp(r'TRANSCRIBE_TIMEOUT_MS"\) \?\? "(\d+)"').firstMatch(fn);
      expect(ours, isNotNull);
      expect(int.parse(ours!.group(1)!), lessThan(125000));

      // Отказ пишется туда же, куда разбор: молчание неотличимо от «ещё
      // думаю», и приложение ждало бы файл, которого не будет.
      expect(fn, contains('await put({ error:'));

      final client = File('lib/data/track_transcriber.dart').readAsStringSync();
      expect(client, contains('_awaitResult(resultPath)'));
      // Старый результат убираем ДО начала: иначе позапрошлая ошибка
      // прочитается мгновенно и выдаст себя за сегодняшнюю.
      expect(
        client.indexOf('remove([resultPath])'),
        lessThan(client.indexOf('functions.invoke')),
      );
    });

    test('сервер приводит ответ к канону сам', () {
      // Клиент терпелив, но канон делает сервер: разбирать один и тот же
      // ответ по-разному в двух местах — значит однажды разойтись.
      final fn = File('supabase/functions/transcribe-track/index.ts')
          .readAsStringSync();
      expect(fn, contains('function linesOf('));
      expect(fn, contains('function asWord('));
      // Массив, все элементы которого слова, — это строка; любой другой —
      // список строк, и в него надо спуститься.
      expect(fn, contains('words.every((w) => w !== null)'));
      expect(fn, contains('node.flatMap(linesOf)'));
      // Строка во всю запись — сломанный экран: он показывает одну строку
      // за раз и ужимает её по ширине.
      expect(fn, contains('splitLong'));
    });
  });

  group('выбор модели разбора', () {
    test('списки на клиенте и на сервере совпадают', () {
      // Разойдясь, они дадут игроку выбор, который сервер молча заменит
      // своим, — то есть настройку, которая ничего не меняет.
      final client = RegExp(r"const List<String> listeningModels = \[(.*?)\];", dotAll: true)
          .firstMatch(File('lib/data/judge_models.dart').readAsStringSync());
      final server = RegExp(r"const LISTENING_MODELS = \[(.*?)\] as const;", dotAll: true)
          .firstMatch(File('supabase/functions/transcribe-track/index.ts').readAsStringSync());
      expect(client, isNotNull);
      expect(server, isNotNull);
      List<String> names(String body) =>
          RegExp(r"""['\"]([\w.\-]+)['\"]""").allMatches(body).map((m) => m.group(1)!).toList();
      expect(names(client!.group(1)!), names(server!.group(1)!));
    });

    test('по умолчанию — распознаватель, а не omni', () {
      // Время у omni выдуманное, и первая живая проверка это показала:
      // субтитры сильно разъехались со звуком.
      final models = File('lib/data/judge_models.dart').readAsStringSync();
      final list = RegExp(r"const List<String> listeningModels = \[(.*?)\];", dotAll: true)
          .firstMatch(models)!
          .group(1)!;
      expect(
        RegExp(r"'([\w.\-]+)'").firstMatch(list)!.group(1),
        'qwen-audio-3.0-asr-flash',
      );
    });

    test('модель берётся из профиля, а не из запроса', () {
      // Называть модель платного провайдера клиенту не дают — так же, как
      // это устроено у боевого воркера.
      final fn = File('supabase/functions/transcribe-track/index.ts').readAsStringSync();
      expect(fn, contains('.select("listening_model, translation_model")'));
      expect(fn.contains('body.model'), isFalse);
    });

    test('перевод идёт построчно — сопоставлять нечего', () {
      // Перевод, поехавший относительно оригинала, разъезжается молча и до
      // конца записи. Список пришлось бы просить у модели структурой, и
      // тогда эта опасность возвращается. Одна строка на вызов — и
      // сопоставлять нечего: что отдали, то и получили.
      final fn = File('supabase/functions/transcribe-track/index.ts').readAsStringSync();
      expect(fn, contains('async function translateLines('));
      expect(fn, contains('text: `Translate into \${target}:'));
      expect(fn.contains('JSON.stringify(slice)'), isFalse,
          reason: 'перевод снова просят списком — он снова сможет поехать');
    });

    test('переводчики — отдельная настройка и отдельный список', () {
      // Шага два, и мерить их надо порознь: плохая разметка и плохой
      // перевод — разные беды с разными лекарствами.
      final client = RegExp(r"const List<String> translationModels = \[(.*?)\];", dotAll: true)
          .firstMatch(File('lib/data/judge_models.dart').readAsStringSync());
      final server = RegExp(r"const TRANSLATION_MODELS = \[(.*?)\] as const;", dotAll: true)
          .firstMatch(File('supabase/functions/transcribe-track/index.ts').readAsStringSync());
      expect(client, isNotNull);
      expect(server, isNotNull);
      List<String> names(String body) =>
          RegExp(r'''['"]([\w.\-]+)['"]''').allMatches(body).map((m) => m.group(1)!).toList();
      expect(names(client!.group(1)!), names(server!.group(1)!));
      expect(names(client.group(1)!), everyElement(startsWith('qwen-mt-')));
    });

    test('нет разметки — показываем ответ, а не гадаем', () {
      final fn = File('supabase/functions/transcribe-track/index.ts').readAsStringSync();
      expect(fn, contains('распознаватель не вернул разметку по времени'));
      expect(fn, contains('sample: heard.body.slice(0, 400)'));
    });
  });

  group('энергия одна на всё приложение', () {
    test('Арена перечитывает кошелёк после фонотеки', () {
      // Арена живёт в оболочке с сохранением состояния и сама ничего не
      // перечитывает: экран поверх неё энергию тратил, а на Арене
      // оставалось прежнее число. Счётчик при этом ОДИН.
      final arena =
          File('lib/features/arena/arena_screen.dart').readAsStringSync();
      final at = arena.indexOf("push('/listening')");
      expect(at, greaterThan(0));
      expect(arena.substring(at, at + 80), contains('_load()'));
    });

    test('восстановление — одна единица за 10 секунд', () {
      final sql = File('supabase/migrations/0053_energy_regen_seconds.sql')
          .readAsStringSync();
      expect(sql, contains('v_step_seconds constant integer := 10'));
      // Считаем в секундах: деление целых минут при шаге в 10 секунд дало
      // бы ноль всегда, и энергия не восстанавливалась бы вовсе.
      expect(sql, contains('extract(epoch from (now() - v_wallet.energy_last_regen_at))'));
      expect(sql.contains('/ 60)'), isFalse);
    });
  });

  group('путь записи в хранилище', () {
    // ПРО ЭТОТ ПУТЬ ЗНАЮТ ТРИ МЕСТА, И СОГЛАСОВАННОСТЬ ДВУХ ИЗ НИХ
    // ВЫГЛЯДИТ КАК РАБОТАЮЩАЯ ФУНКЦИЯ. Клиент собирает путь, функция
    // разбора по нему же проверяет, что запись не чужая, а ПРАВО писать по
    // этому пути живёт в политиках хранилища. Первые два совпадали, третьего
    // не было вовсе — и живой разбор отказывал на первом же шаге:
    // «new row violates row-level security policy», 403.
    const prefix = 'tracks/';

    test('клиент и функция разбора говорят об одном пути', () {
      expect(
        File('lib/data/track_transcriber.dart').readAsStringSync(),
        contains("'$prefix\$currentUserId/"),
      );
      expect(
        File('supabase/functions/transcribe-track/index.ts').readAsStringSync(),
        contains('`$prefix\${userId}/`'),
      );
    });

    test('хранилище разрешает по этому пути всё, что делает клиент', () {
      // Клиент кладёт (с upsert) и удаляет. Не хватит любой из политик —
      // и отказ придёт либо на загрузке, либо на уборке за собой; вторая
      // молча оставила бы чужую запись у нас на сервере навсегда.
      final sql = File('supabase/migrations/0052_listening_track_uploads.sql')
          .readAsStringSync();
      expect(sql, contains("(storage.foldername(name))[1] = 'tracks'"));
      expect(sql, contains('(storage.foldername(name))[2] = auth.uid()::text'));
      for (final action in ['select', 'insert', 'update', 'delete']) {
        expect(sql, contains('on storage.objects for $action'), reason: action);
      }
      // upsert: true — это обновление существующего объекта, и без with
      // check на update оно отказывает (ровно та же ловушка, что в 0045).
      expect(sql, contains('with check (bucket_id'));
    });

    test('условие пути записано один раз, а не в каждой политике', () {
      // Четыре копии одного условия разъезжаются молча, и разъехавшись
      // дают право писать туда, откуда нельзя удалить.
      final sql = File('supabase/migrations/0052_listening_track_uploads.sql')
          .readAsStringSync();
      expect(sql, contains('function public.own_listening_track(name text)'));
      // Пять, а не четыре: у политики на обновление условие стоит дважды —
      // в using (что можно трогать) и в with check (чем можно заменить).
      expect('public.own_listening_track(name)'.allMatches(sql).length, 5);
      // auth.uid() внутри — значит STABLE, а не IMMUTABLE: обещав
      // планировщику неизменность, мы разрешили бы применить результат
      // одного игрока к запросу другого.
      expect(sql.contains('immutable'), isFalse);
      expect(sql, contains('stable'));
    });
  });

  group('энергия за разбор', () {
    String fn() =>
        File('supabase/functions/transcribe-track/index.ts').readAsStringSync();

    test('нехватку ловит сервер, а не плашка на клиенте', () {
      // spend_energy при нехватке НЕ падает: списывает сколько есть и
      // возвращает остаток. Без проверки единственным заслоном оставалась
      // бы плашка по кошельку, который мог устареть, — то есть разбор за
      // полцены и никакого отказа.
      final s = fn();
      expect(s, contains('asUser.rpc("sync_wallet")'));
      expect(s, contains('if (energyLeft < cost)'));
      expect(s, contains('402'));
    });

    test('причина отказа доезжает до игрока словами', () {
      // На любой ответ кроме 2xx клиент бросает FunctionException, и
      // '$e' показал бы «FunctionsHttpException(status: 402, details: …)»
      // вместо «нужно 6 энергии, а есть 2».
      final client = File('lib/data/track_transcriber.dart').readAsStringSync();
      expect(client, contains('on FunctionException catch (e)'));
      expect(client, contains("details['error']"));
    });

    test('сначала ссылка, потом списание, потом модель', () {
      // Не собралась ссылка — модель мы даже не звали, и брать за это
      // плату не за что. Порядок смотрим В САМОМ ОБРАБОТЧИКЕ: вызовы
      // модели живут во вспомогательных функциях, и поиск по всему файлу
      // находил бы их, а не ход запроса.
      final all = fn();
      final s = all.substring(all.indexOf('Deno.serve('));
      expect(
        s.indexOf('audioUrlFor(storagePath'),
        lessThan(s.indexOf('rpc("spend_energy"')),
      );
      expect(
        s.indexOf('rpc("spend_energy"'),
        lessThan(s.indexOf('transcribe({')),
        reason: 'модель зовётся только после списания',
      );
    });
  });
}
