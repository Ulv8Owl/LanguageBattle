import 'package:flutter/material.dart';

import '../../core/all_languages.dart';
import '../../core/supabase_client.dart';
import '../../core/theme.dart';
import '../../data/player_rating.dart';
import '../../widgets/chrolingo_widgets.dart';

/// Публичная карточка игрока — открывается тапом по аватарке в шапке боя.
///
/// Показывает только то, что и так видно сопернику по ходу матча: имя,
/// рейтинг и лигу, языковую пару. Ни почты, ни внутренних идентификаторов
/// — карточку смотрит посторонний человек.
Future<void> showPlayerCard(
  BuildContext context, {
  required String userId,
  required String name,
  required bool isMe,
}) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: AppColors.navy2,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (_) => _PlayerCard(userId: userId, name: name, isMe: isMe),
  );
}

class _PlayerCard extends StatefulWidget {
  final String userId;
  final String name;
  final bool isMe;

  const _PlayerCard({required this.userId, required this.name, required this.isMe});

  @override
  State<_PlayerCard> createState() => _PlayerCardState();
}

class _PlayerCardState extends State<_PlayerCard> {
  bool _loading = true;
  String? _error;
  PlayerRating _rating = PlayerRating.newcomer;
  String _learning = '';
  String _native = '';

  /// Уже друзья или заявка отправлена — тогда кнопки приглашения нет.
  bool _friendshipExists = false;
  bool _inviting = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final user = await supabase
          .from('users')
          .select('native_language')
          .eq('id', widget.userId)
          .maybeSingle();
      final learning = await supabase
          .from('user_languages')
          .select('language_code, ${PlayerRating.columns}')
          .eq('user_id', widget.userId)
          .eq('role', 'learning')
          .eq('is_active', true)
          .limit(1)
          .maybeSingle();

      var exists = false;
      if (!widget.isMe) {
        // Дружба хранится одной строкой на пару, поэтому смотрим оба
        // направления: иначе уже добавленный друг снова получал бы заявку.
        final rows = await supabase
            .from('friendships')
            .select('user_id')
            .or('and(user_id.eq.$currentUserId,friend_id.eq.${widget.userId}),'
                'and(user_id.eq.${widget.userId},friend_id.eq.$currentUserId)')
            .limit(1);
        exists = rows.isNotEmpty;
      }

      if (!mounted) return;
      setState(() {
        _native = (user?['native_language'] as String?) ?? '';
        _learning = (learning?['language_code'] as String?) ?? '';
        _rating = PlayerRating.fromRow(learning);
        _friendshipExists = exists;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Не удалось загрузить профиль: $e';
        _loading = false;
      });
    }
  }

  Future<void> _invite() async {
    setState(() => _inviting = true);
    try {
      await supabase.from('friendships').insert({
        'user_id': currentUserId,
        'friend_id': widget.userId,
        // Тот же статус, что и на экране «Друзья»: заводить здесь свой
        // порядок подтверждения значило бы, что заявка из боя и заявка из
        // списка друзей ведут себя по-разному.
        'status': 'accepted',
      });
      if (!mounted) return;
      setState(() {
        _friendshipExists = true;
        _inviting = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Заявка отправлена: ${widget.name}')),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _inviting = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Не удалось отправить заявку: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final league = _rating.league;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 14, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              height: 4,
              width: 40,
              decoration: BoxDecoration(
                color: AppColors.lineStrong,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 18),
            // Аватарка крупно — «рассмотреть поближе» и есть одна из причин
            // сюда заходить.
            ChAvatar(name: widget.name, size: 96, ringColor: league.color),
            const SizedBox(height: 12),
            Text(widget.name, style: AppFonts.ui(fontSize: 18, weight: FontWeight.w800, color: AppColors.cream)),
            const SizedBox(height: 16),
            if (_loading)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 20),
                child: CircularProgressIndicator(),
              )
            else if (_error != null)
              Text(_error!, style: const TextStyle(color: AppColors.danger, fontSize: 12))
            else ...[
              ChPanel(
                child: Column(
                  children: [
                    _row('Лига', league.name, league.color),
                    const Divider(height: 18, color: AppColors.line),
                    _row('Рейтинг', '${_rating.display}', AppColors.cream),
                    const Divider(height: 18, color: AppColors.line),
                    _row(
                      'Языковая пара',
                      _learning.isEmpty
                          ? '—'
                          : '${languageName(_native)} → ${languageName(_learning)}',
                      AppColors.cream,
                    ),
                  ],
                ),
              ),
              if (!widget.isMe) ...[
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  child: _friendshipExists
                      ? OutlinedButton(
                          onPressed: null,
                          child: const Text('Заявка уже есть'),
                        )
                      : ElevatedButton.icon(
                          onPressed: _inviting ? null : _invite,
                          icon: _inviting
                              ? const SizedBox(
                                  height: 14,
                                  width: 14,
                                  child: CircularProgressIndicator(strokeWidth: 2),
                                )
                              : const Icon(Icons.person_add_alt),
                          label: const Text('Пригласить в друзья'),
                        ),
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }

  Widget _row(String label, String value, Color valueColor) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label, style: AppFonts.mono(fontSize: 10, weight: FontWeight.w700, color: AppColors.muted)),
        Text(value, style: AppFonts.ui(fontSize: 13, weight: FontWeight.w700, color: valueColor)),
      ],
    );
  }
}
