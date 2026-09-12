import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/supabase_client.dart';
import '../core/theme.dart';
import '../data/chat.dart';
import 'ai_avatar.dart';
import 'chrolingo_widgets.dart';

/// Мини-чат с соперником на экране итогов.
///
/// ЗАЧЕМ ОН ЗДЕСЬ. Итоги — единственная точка, где оба игрока стоят рядом и
/// уже ничего не решают: бой сыгран, счёт известен. Сказать друг другу
/// «хорошо сыграл» или позвать на реванш больше негде — в самом бою чат
/// был бы подсказкой сопернику.
///
/// ПОКА СОПЕРНИК ЗДЕСЬ. Присутствие второй стороны видно по-настоящему
/// (Realtime presence), а не угадывается по последнему сообщению: ушедший
/// с экрана соперник не получит ни сообщения, ни вызова на реванш, и
/// честнее сказать об этом сразу, чем дать написать в пустоту.
///
/// ПЕРЕПИСКА ОСТАЁТСЯ В БАЗЕ и переживает выход с экрана: вернувшись на
/// итоги, игрок увидит, что ему писали. Умирает она вместе с матчем.
class MatchChatPanel extends StatefulWidget {
  final String matchId;
  final String myId;
  final String? opponentId;
  final String myName;
  final String opponentName;
  final Map<String, String> myAvatar;
  final Map<String, String> opponentAvatar;

  /// Тап по аватарке в переписке — карточка игрока.
  final void Function(String userId, bool isMe) onAvatarTap;

  /// Реванш принят (кем угодно из двоих) — уводим обоих в новый бой.
  final void Function(String newMatchId) onRematchStarted;

  const MatchChatPanel({
    super.key,
    required this.matchId,
    required this.myId,
    required this.opponentId,
    required this.myName,
    required this.opponentName,
    required this.myAvatar,
    required this.opponentAvatar,
    required this.onAvatarTap,
    required this.onRematchStarted,
  });

  @override
  State<MatchChatPanel> createState() => _MatchChatPanelState();
}

class _MatchChatPanelState extends State<MatchChatPanel> {
  final _input = TextEditingController();
  final _scroll = ScrollController();

  RealtimeChannel? _presence;
  bool _opponentHere = false;
  bool _sending = false;
  bool _acceptingRematch = false;

  /// Уже увели в новый бой — второй раз не уводим.
  bool _rematchHandled = false;

  /// Быстрые эмоции. Их ровно шесть и они не настраиваются: строка эмодзи
  /// нужна, чтобы ответить не печатая, а не чтобы выбирать из сотни.
  static const _emotions = ['👍', '🔥', '😄', '😮', '😢', '🤝'];

  @override
  void initState() {
    super.initState();
    _watchPresence();
  }

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    final channel = _presence;
    if (channel != null) supabase.removeChannel(channel);
    super.dispose();
  }

  /// Кто сейчас на этом экране. Ключ присутствия — id игрока: так по списку
  /// сразу видно, здесь ли именно соперник, а не «сколько всего человек».
  void _watchPresence() {
    final channel = supabase.channel(
      'match-results:${widget.matchId}',
      opts: RealtimeChannelConfig(key: widget.myId),
    );
    channel.onPresenceSync((_) {
      if (!mounted) return;
      final ids = channel.presenceState().map((s) => s.key).toSet();
      setState(() => _opponentHere = widget.opponentId != null && ids.contains(widget.opponentId));
    }).subscribe((status, _) async {
      if (status == RealtimeSubscribeStatus.subscribed) {
        await channel.track({'at': DateTime.now().toUtc().toIso8601String()});
      }
    });
    _presence = channel;
  }

  Future<void> _send(String text) async {
    if (_sending) return;
    setState(() => _sending = true);
    try {
      await sendMatchMessage(widget.matchId, text);
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

  Future<void> _acceptRematch() async {
    setState(() => _acceptingRematch = true);
    try {
      final id = await acceptRematch(widget.matchId);
      if (!mounted) return;
      _rematchHandled = true;
      widget.onRematchStarted(id);
    } catch (e) {
      if (!mounted) return;
      setState(() => _acceptingRematch = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Реванш не начался: $e')),
      );
    }
  }

  void _scrollToBottomSoon() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      _scroll.jumpTo(_scroll.position.maxScrollExtent);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.navy1,
        border: Border.all(color: AppColors.gold, width: 2),
        borderRadius: BorderRadius.circular(18),
      ),
      clipBehavior: Clip.antiAlias,
      child: StreamBuilder<List<MatchChatMessage>>(
        stream: matchChatStream(widget.matchId),
        builder: (context, snapshot) {
          final messages = snapshot.data ?? const <MatchChatMessage>[];

          // Реванш принят — уводим в новый бой обоих, и того, кто нажал, и
          // того, кто звал: сообщение о начатом бое приходит в тот же чат.
          final started = messages.where((m) => m.isRematchStarted).toList();
          if (started.isNotEmpty && !_rematchHandled) {
            final newId = started.first.newMatchId;
            if (newId != null) {
              _rematchHandled = true;
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (mounted) widget.onRematchStarted(newId);
              });
            }
          }

          // Кнопка ответа на вызов появляется только у вызванного и только
          // пока бой не начат: звать в ответ на собственный вызов незачем.
          final offeredByOpponent = messages.any((m) => m.isRematchOffer && m.userId != widget.myId);
          final canAnswerRematch = offeredByOpponent && started.isEmpty;

          _scrollToBottomSoon();

          return Column(
            children: [
              _header(),
              Expanded(
                child: messages.isEmpty
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 24),
                          child: Text(
                            'Здесь можно написать сопернику, пока он не ушёл с этого экрана.',
                            textAlign: TextAlign.center,
                            style: AppFonts.ui(fontSize: 12, color: AppColors.muted),
                          ),
                        ),
                      )
                    : ListView.builder(
                        controller: _scroll,
                        padding: const EdgeInsets.fromLTRB(10, 10, 10, 4),
                        itemCount: messages.length,
                        itemBuilder: (context, i) => _bubble(messages[i]),
                      ),
              ),
              if (canAnswerRematch) _rematchAnswer(),
              _composer(),
            ],
          );
        },
      ),
    );
  }

  Widget _header() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: const BoxDecoration(
        color: AppColors.navy2,
        border: Border(bottom: BorderSide(color: AppColors.line)),
      ),
      child: Row(
        children: [
          Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: _opponentHere ? AppColors.ok : AppColors.muted,
            ),
          ),
          const SizedBox(width: 7),
          Expanded(
            child: Text(
              _opponentHere ? '${widget.opponentName} здесь' : '${widget.opponentName} вышел',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppFonts.mono(
                fontSize: 10,
                weight: FontWeight.w700,
                color: _opponentHere ? AppColors.ok : AppColors.muted,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _bubble(MatchChatMessage message) {
    final isMine = message.userId == widget.myId;
    final name = isMine ? widget.myName : widget.opponentName;
    final avatar = isMine ? widget.myAvatar : widget.opponentAvatar;

    // Служебная строка про начатый бой — не чья-то реплика, поэтому по
    // центру и без аватарки: приписывать её игроку было бы неправдой.
    if (message.isRematchStarted) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Center(
          child: Text(
            message.body,
            style: AppFonts.mono(fontSize: 10, weight: FontWeight.w700, color: AppColors.gold),
          ),
        ),
      );
    }

    final accent = message.isRematchOffer
        ? AppColors.gold
        : (isMine ? AppColors.gold : AppColors.cyan);
    final face = GestureDetector(
      onTap: () => widget.onAvatarTap(message.userId, isMine),
      behavior: HitTestBehavior.opaque,
      child: ChAvatar(name: name, avatar: avatar, size: avatarSize, ringColor: accent.withValues(alpha: 0.6)),
    );
    final bubble = Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: isMine ? AppColors.gold.withValues(alpha: 0.14) : AppColors.navy3,
        border: Border.all(color: accent.withValues(alpha: 0.35)),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        message.body,
        style: TextStyle(
          color: message.isRematchOffer ? AppColors.gold : AppColors.cream,
          fontSize: 13,
          height: 1.3,
          fontWeight: message.isRematchOffer ? FontWeight.w800 : FontWeight.w400,
        ),
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
  }

  Widget _rematchAnswer() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 4, 10, 0),
      child: SizedBox(
        width: double.infinity,
        child: ElevatedButton.icon(
          onPressed: _acceptingRematch ? null : _acceptRematch,
          icon: _acceptingRematch
              ? const SizedBox(height: 14, width: 14, child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.replay),
          label: const Text('Ответить на Реванш'),
        ),
      ),
    );
  }

  Widget _composer() {
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 6, 6, 6),
      decoration: const BoxDecoration(
        color: AppColors.navy2,
        border: Border(top: BorderSide(color: AppColors.line)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            height: 30,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: _emotions.length,
              separatorBuilder: (context, i) => const SizedBox(width: 4),
              itemBuilder: (context, i) => InkWell(
                onTap: _sending ? null : () => _send(_emotions[i]),
                borderRadius: BorderRadius.circular(8),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  child: Center(child: Text(_emotions[i], style: const TextStyle(fontSize: 17))),
                ),
              ),
            ),
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _input,
                  minLines: 1,
                  maxLines: 3,
                  textInputAction: TextInputAction.send,
                  onSubmitted: _send,
                  style: const TextStyle(color: AppColors.cream, fontSize: 13),
                  decoration: const InputDecoration(
                    isDense: true,
                    border: InputBorder.none,
                    hintText: 'Написать сопернику…',
                    hintStyle: TextStyle(color: AppColors.muted, fontSize: 12),
                  ),
                ),
              ),
              IconButton(
                onPressed: _sending ? null : () => _send(_input.text),
                icon: const Icon(Icons.send, color: AppColors.gold, size: 20),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
