import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/supabase_client.dart';
import '../../core/theme.dart';
import '../../data/chat.dart';
import '../../widgets/chrolingo_widgets.dart';
import '../battle/player_card_sheet.dart';
import 'friends_screen.dart';

/// Переписка с друзьями — ВЫДВИЖНАЯ ПАНЕЛЬ ВНУТРИ РАЗДЕЛА, не экран.
///
/// ПОЧЕМУ НЕ ЭКРАН И НЕ РАЗДЕЛ. Внизу четыре кнопки, и пятая размыла бы
/// то, ради чего в приложение заходят: играть. Отдельный экран не лучше:
/// открыть его — значит уйти из списка друзей, а переписка это спутник
/// списка, а не другое место. Поэтому чат живёт ЗДЕСЬ ЖЕ, под вкладками,
/// и раскрывается вниз — панель растёт, а раздел остаётся тем же.
///
/// ГРУЗИТСЯ ВМЕСТЕ С РАЗДЕЛОМ, А НЕ ПРИ ОТКРЫТИИ. Панель живёт в дереве
/// всегда — в закрытом виде у неё просто нулевая высота (см. Align с
/// heightFactor в friends_screen.dart). Поэтому подписка на переписку уже
/// работает к тому моменту, когда игрок потянул полоску, и раскрытый чат
/// не начинается с пустого экрана и спиннера.
///
/// ЛЕНТА АВАТАРОК СВЕРХУ — ЭТО И ЕСТЬ СПИСОК ДИАЛОГОВ. Списка строк с
/// последним сообщением здесь нет намеренно: на телефоне он занял бы
/// половину экрана, а собеседников у игрока единицы. Аватарка с именем
/// узнаётся быстрее строки, а порядок говорит то же, что сказал бы список:
/// кто писал последним, тот левее.
///
/// ЗАКРЕПЛЕНИЕ держит нужного человека на месте, когда лента двигается.
/// Оно своё у каждого (см. friend_chat_pins в миграции 0049): закрепив
/// друга, я не закрепляю себя у него.
class FriendsChatPanel extends StatefulWidget {
  /// С кем открыт чат. Значением владеет раздел: «Написать» в строке друга
  /// выбирает собеседника и раскрывает панель одним действием.
  final String? selectedFriendId;

  /// Игрок выбрал собеседника сам — тапом по аватарке в ленте.
  final ValueChanged<String> onSelected;

  const FriendsChatPanel({
    super.key,
    required this.selectedFriendId,
    required this.onSelected,
  });

  @override
  State<FriendsChatPanel> createState() => _FriendsChatPanelState();
}

class _FriendsChatPanelState extends State<FriendsChatPanel> {
  final String _myId = currentUserId;
  final _input = TextEditingController();
  final _scroll = ScrollController();

  List<PlayerRef> _friends = [];
  Map<String, String> _myAvatarByPart = const {};
  String _myName = 'Ты';
  Set<String> _pinned = {};

  /// Кого показываем, когда раздел ничего не выбрал: первый в ленте.
  String? _fallback;
  bool _loading = true;
  bool _sending = false;

  /// Выбранный собеседник: сначала то, что просит раздел, иначе первый.
  String? get _selected => widget.selectedFriendId ?? _fallback;

  List<DirectMessage> _messages = [];
  StreamSubscription? _messagesSub;

  @override
  void initState() {
    super.initState();
    _load();
    // Одна подписка на всю переписку: переключение собеседника не должно
    // пересоздавать сессию Realtime на каждом нажатии (см. chat.dart).
    _messagesSub = directMessagesStream().listen((rows) {
      if (!mounted) return;
      setState(() => _messages = rows);
      _scrollToBottomSoon();
    });
  }

  @override
  void dispose() {
    _messagesSub?.cancel();
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final asUser = await supabase
          .from('friendships')
          .select('friend_id')
          .eq('user_id', _myId)
          .eq('status', 'accepted');
      final asFriend = await supabase
          .from('friendships')
          .select('user_id')
          .eq('friend_id', _myId)
          .eq('status', 'accepted');
      final ids = <String>{
        for (final r in asUser) r['friend_id'] as String,
        for (final r in asFriend) r['user_id'] as String,
      };
      final players = await loadPlayers({...ids, _myId});
      final pins = await loadChatPins();
      if (!mounted) return;
      setState(() {
        _friends = ids.map((id) => players[id]).whereType<PlayerRef>().toList();
        _myName = players[_myId]?.username ?? 'Ты';
        _myAvatarByPart = players[_myId]?.avatar ?? const {};
        _pinned = pins;
        _fallback = _friends.isNotEmpty ? _ordered().first.id : null;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Не удалось загрузить друзей: $e')),
      );
    }
  }

  /// Когда с этим человеком в последний раз говорили. null — никогда.
  DateTime? _lastTalk(String friendId) {
    DateTime? last;
    for (final m in _messages) {
      if (m.otherSide(_myId) != friendId) continue;
      if (last == null || m.createdAt.isAfter(last)) last = m.createdAt;
    }
    return last;
  }

  /// Порядок ленты: закреплённые, потом по последнему сообщению, потом
  /// остальные по имени. Молчаливый друг не должен тонуть в конце навсегда
  /// — он просто стоит после тех, с кем разговор идёт.
  List<PlayerRef> _ordered() {
    final list = [..._friends];
    list.sort((a, b) {
      final pinnedA = _pinned.contains(a.id);
      final pinnedB = _pinned.contains(b.id);
      if (pinnedA != pinnedB) return pinnedA ? -1 : 1;
      final lastA = _lastTalk(a.id);
      final lastB = _lastTalk(b.id);
      if (lastA != null && lastB != null) return lastB.compareTo(lastA);
      if (lastA != null) return -1;
      if (lastB != null) return 1;
      return a.username.toLowerCase().compareTo(b.username.toLowerCase());
    });
    return list;
  }

  List<DirectMessage> _thread(String friendId) =>
      _messages.where((m) => m.otherSide(_myId) == friendId).toList();

  Future<void> _togglePin(PlayerRef friend) async {
    final pinned = _pinned.contains(friend.id);
    setState(() {
      if (pinned) {
        _pinned.remove(friend.id);
      } else {
        _pinned.add(friend.id);
      }
    });
    try {
      await setChatPin(friend.id, !pinned);
    } catch (e) {
      if (!mounted) return;
      // Не сохранилось — возвращаем как было, иначе экран врёт о том, что
      // закрепление пережило бы перезаход.
      setState(() {
        if (pinned) {
          _pinned.add(friend.id);
        } else {
          _pinned.remove(friend.id);
        }
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Не удалось закрепить: $e')),
      );
    }
  }

  Future<void> _send() async {
    final friendId = _selected;
    final text = _input.text.trim();
    if (friendId == null || text.isEmpty || _sending) return;
    setState(() => _sending = true);
    try {
      await sendDirectMessage(friendId, text);
      _input.clear();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Сообщение не отправилось: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  void _scrollToBottomSoon() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      _scroll.jumpTo(_scroll.position.maxScrollExtent);
    });
  }

  void _openCard(String userId, String name, bool isMe) =>
      showPlayerCard(context, userId: userId, name: name, isMe: isMe);

  @override
  Widget build(BuildContext context) {
    final friends = _ordered();
    final selected = _selected;
    final friend = friends.where((f) => f.id == selected).firstOrNull;

    // ПАНЕЛЬ, А НЕ ЭКРАН: ни Scaffold, ни шапки. Заголовок здесь был бы
    // вторым после вкладок раздела, а сама панель по ширине такая же, как
    // плашки друзей под ней, — она их продолжение, а не отдельное окно.
    return Container(
      decoration: BoxDecoration(
        color: AppColors.navy2,
        border: Border.all(color: AppColors.line),
        borderRadius: BorderRadius.circular(14),
      ),
      clipBehavior: Clip.antiAlias,
      child: _loading
          ? const Center(child: CircularProgressIndicator())
          : friends.isEmpty
              ? const Center(
                  child: Padding(
                    padding: EdgeInsets.symmetric(horizontal: 32),
                    child: Text(
                      'Писать пока некому — добавь друзей во вкладке «Поиск».',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: AppColors.muted, fontSize: 12),
                    ),
                  ),
                )
              : Column(
                  children: [
                    _strip(friends),
                    const Divider(height: 1, color: AppColors.line),
                    Expanded(child: friend == null ? const SizedBox.shrink() : _threadView(friend)),
                    if (friend != null) _composer(friend),
                  ],
                ),
    );
  }

  /// Лента собеседников. Долгое нажатие закрепляет — отдельной кнопки на
  /// аватарке нет: она бы стояла на каждой из них ради редкого действия.
  Widget _strip(List<PlayerRef> friends) {
    return SizedBox(
      height: 92,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        itemCount: friends.length,
        separatorBuilder: (context, i) => const SizedBox(width: 10),
        itemBuilder: (context, i) {
          final f = friends[i];
          final isSelected = f.id == _selected;
          final isPinned = _pinned.contains(f.id);
          return GestureDetector(
            onTap: () => widget.onSelected(f.id),
            onLongPress: () => _togglePin(f),
            behavior: HitTestBehavior.opaque,
            child: SizedBox(
              width: 62,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Stack(
                    clipBehavior: Clip.none,
                    children: [
                      ChAvatar(
                        name: f.username,
                        avatar: f.avatar,
                        size: 48,
                        // Золотая обводка = выбранный диалог. Другого
                        // признака «этот открыт» на ленте нет.
                        ringColor: isSelected ? AppColors.gold : AppColors.lineStrong,
                        glow: isSelected,
                      ),
                      if (isPinned)
                        const Positioned(
                          right: -2,
                          top: -2,
                          child: Icon(Icons.push_pin, size: 13, color: AppColors.gold),
                        ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    f.username,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: AppFonts.mono(
                      fontSize: 9,
                      weight: FontWeight.w700,
                      color: isSelected ? AppColors.gold : AppColors.muted,
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _threadView(PlayerRef friend) {
    final thread = _thread(friend.id);
    if (thread.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Text(
            'С ${friend.username} вы ещё не переписывались.',
            textAlign: TextAlign.center,
            style: AppFonts.ui(fontSize: 12, color: AppColors.muted),
          ),
        ),
      );
    }
    return ListView.builder(
      controller: _scroll,
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
      itemCount: thread.length,
      itemBuilder: (context, i) {
        final message = thread[i];
        final isMine = message.senderId == _myId;
        final name = isMine ? _myName : friend.username;
        final accent = isMine ? AppColors.gold : AppColors.cyan;
        final face = GestureDetector(
          onTap: () => _openCard(message.senderId, name, isMine),
          behavior: HitTestBehavior.opaque,
          child: ChAvatar(
            name: name,
            avatar: isMine ? _myAvatarByPart : friend.avatar,
            size: 28,
            ringColor: accent.withValues(alpha: 0.6),
          ),
        );
        final bubble = Container(
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 8),
          decoration: BoxDecoration(
            color: isMine ? AppColors.gold.withValues(alpha: 0.14) : AppColors.navy3,
            border: Border.all(color: accent.withValues(alpha: 0.35)),
            borderRadius: BorderRadius.circular(13),
          ),
          child: Text(
            message.body,
            style: const TextStyle(color: AppColors.cream, fontSize: 13, height: 1.35),
          ),
        );
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Row(
            mainAxisAlignment: isMine ? MainAxisAlignment.end : MainAxisAlignment.start,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: isMine
                ? [Flexible(child: bubble), const SizedBox(width: 7), face]
                : [face, const SizedBox(width: 7), Flexible(child: bubble)],
          ),
        );
      },
    );
  }

  Widget _composer(PlayerRef friend) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 6, 6, 8),
      decoration: const BoxDecoration(
        color: AppColors.navy2,
        border: Border(top: BorderSide(color: AppColors.line)),
      ),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _input,
              minLines: 1,
              maxLines: 4,
              textInputAction: TextInputAction.send,
              onSubmitted: (_) => _send(),
              style: const TextStyle(color: AppColors.cream, fontSize: 13),
              decoration: InputDecoration(
                isDense: true,
                border: InputBorder.none,
                hintText: 'Написать ${friend.username}…',
                hintStyle: const TextStyle(color: AppColors.muted, fontSize: 12),
              ),
            ),
          ),
          IconButton(
            onPressed: _sending ? null : _send,
            icon: const Icon(Icons.send, color: AppColors.gold, size: 20),
          ),
        ],
      ),
    );
  }
}
