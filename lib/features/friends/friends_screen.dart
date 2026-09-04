import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/supabase_client.dart';
import '../../core/all_languages.dart';
import '../../core/theme.dart';
import '../../data/player_rating.dart';
import '../../widgets/chrolingo_widgets.dart';

/// Флаг по коду языка. Отдельного поля "страна" в схеме нет (раздел 4),
/// поэтому флаг берётся по родному языку игрока — это ближайшие реальные
/// данные, а не выдуманные.
/// Карточка игрока: имя, флаг, рейтинг — одинаково во всех трёх вкладках
/// (раздел 5.1, п.8).
class PlayerRef {
  final String id;
  final String username;
  final String? nativeLanguage;
  final PlayerRating rating;

  const PlayerRef({
    required this.id,
    required this.username,
    required this.nativeLanguage,
    required this.rating,
  });

  String get flag => languageFlag(nativeLanguage);
}

/// Подтягивает имя/флаг/рейтинг для набора id одним заходом.
Future<Map<String, PlayerRef>> loadPlayers(Iterable<String> ids) async {
  final list = ids.toSet().toList();
  if (list.isEmpty) return {};
  final users = await supabase.from('users').select('id, username, native_language').inFilter('id', list);
  final langs = await supabase
      .from('user_languages')
      .select('user_id, ${PlayerRating.columns}')
      .inFilter('user_id', list)
      .eq('role', 'learning')
      .eq('is_active', true);
  final ratingById = <String, PlayerRating>{
    for (final row in langs)
      row['user_id'] as String: PlayerRating.fromRow(Map<String, dynamic>.from(row)),
  };
  return {
    for (final row in users)
      row['id'] as String: PlayerRef(
        id: row['id'] as String,
        username: (row['username'] as String?) ?? 'Игрок',
        nativeLanguage: row['native_language'] as String?,
        rating: ratingById[row['id'] as String] ?? PlayerRating.newcomer,
      ),
  };
}

class FriendsScreen extends StatefulWidget {
  const FriendsScreen({super.key});

  @override
  State<FriendsScreen> createState() => _FriendsScreenState();
}

class _FriendsScreenState extends State<FriendsScreen> {
  int _tab = 0;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          ChTabBar(
            tabs: const ['Друзья', 'Рейтинг', 'Поиск'],
            selected: _tab,
            onChanged: (i) => setState(() => _tab = i),
          ),
          const SizedBox(height: 14),
          Expanded(
            child: IndexedStack(
              index: _tab,
              children: const [_FriendsListTab(), _LeaderboardTab(), _SearchTab()],
            ),
          ),
        ],
      ),
    );
  }
}

// =====================================================================
// Вкладка «Друзья» + группа
// =====================================================================

class _FriendsListTab extends StatefulWidget {
  const _FriendsListTab();

  @override
  State<_FriendsListTab> createState() => _FriendsListTabState();
}

class _FriendsListTabState extends State<_FriendsListTab> {
  List<PlayerRef> _friends = [];
  bool _loading = true;
  bool _busy = false;

  /// Участники моей группы (максимум 2 вместе со мной), пусто — группы нет.
  List<PlayerRef> _party = [];

  /// Входящие приглашения в группу.
  List<Map<String, dynamic>> _invites = [];
  Map<String, PlayerRef> _inviters = {};

  StreamSubscription? _inviteSub;

  @override
  void initState() {
    super.initState();
    _load();
    // Приглашение от друга должно появляться без перезахода на вкладку.
    _inviteSub = supabase
        .from('party_invites')
        .stream(primaryKey: ['id'])
        .eq('to_user_id', currentUserId)
        .listen((_) {
      if (mounted) _load();
    });
  }

  @override
  void dispose() {
    _inviteSub?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    final uid = currentUserId;
    try {
      final asUser = await supabase.from('friendships').select().eq('user_id', uid).eq('status', 'accepted');
      final asFriend = await supabase.from('friendships').select().eq('friend_id', uid).eq('status', 'accepted');
      final friendIds = <String>{
        for (final r in asUser) r['friend_id'] as String,
        for (final r in asFriend) r['user_id'] as String,
      };

      final myMembership = await supabase
          .from('party_members')
          .select('party_id')
          .eq('user_id', uid)
          .maybeSingle();
      var partyMembers = <PlayerRef>[];
      if (myMembership != null) {
        final rows = await supabase
            .from('party_members')
            .select('user_id')
            .eq('party_id', myMembership['party_id'] as String);
        final memberIds = rows.map((r) => r['user_id'] as String).toList();
        final players = await loadPlayers(memberIds);
        partyMembers = memberIds.map((id) => players[id]).whereType<PlayerRef>().toList();
      }

      final invites = await supabase
          .from('party_invites')
          .select()
          .eq('to_user_id', uid)
          .eq('status', 'pending');
      final inviterIds = invites.map((r) => r['from_user_id'] as String).toList();

      final friendPlayers = await loadPlayers(friendIds);
      final inviterPlayers = await loadPlayers(inviterIds);

      if (!mounted) return;
      setState(() {
        // Сортировка по консервативной оценке, а не по сырому рейтингу:
        // иначе новичок с двумя удачными матчами и RD 250 оказался бы
        // выше того, кто эти очки действительно наиграл.
        _friends = friendPlayers.values.toList()
          ..sort((a, b) => b.rating.leagueRating.compareTo(a.rating.leagueRating));
        _party = partyMembers;
        _invites = List<Map<String, dynamic>>.from(invites);
        _inviters = inviterPlayers;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      _toast('Не удалось загрузить друзей: $e');
    }
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _call(PlayerRef friend) async {
    setState(() => _busy = true);
    try {
      await supabase.rpc('party_invite', params: {'p_friend_id': friend.id});
      _toast('Приглашение отправлено: ${friend.username}');
      await _load();
    } catch (e) {
      final message = e.toString();
      if (message.contains('party_full')) {
        _toast('В группе максимум 2 игрока');
      } else if (message.contains('player_already_in_party')) {
        _toast('Игрок уже состоит в группе');
      } else {
        _toast('Не удалось позвать: $e');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _acceptInvite(String inviteId) async {
    setState(() => _busy = true);
    try {
      await supabase.rpc('party_accept', params: {'p_invite_id': inviteId});
      await _load();
    } catch (e) {
      _toast('Не удалось принять: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _declineInvite(String inviteId) async {
    try {
      await supabase.rpc('party_decline', params: {'p_invite_id': inviteId});
      await _load();
    } catch (e) {
      _toast('Не удалось отклонить: $e');
    }
  }

  Future<void> _leaveParty() async {
    setState(() => _busy = true);
    try {
      await supabase.rpc('party_leave');
      await _load();
    } catch (e) {
      _toast('Не удалось покинуть группу: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());

    // Группа считается собранной, когда в ней есть кто-то кроме меня.
    final inParty = _party.length > 1;

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        children: [
          for (final invite in _invites)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: _InviteCard(
                inviter: _inviters[invite['from_user_id'] as String],
                busy: _busy,
                onAccept: () => _acceptInvite(invite['id'] as String),
                onDecline: () => _declineInvite(invite['id'] as String),
              ),
            ),
          if (inParty) ...[
            _PartyPanel(members: _party, busy: _busy, onLeave: _leaveParty),
            const SizedBox(height: 14),
          ],
          if (_friends.isEmpty)
            const Padding(
              padding: EdgeInsets.only(top: 40),
              child: Center(
                child: Text('Пока нет друзей — найди их во вкладке «Поиск».',
                    style: TextStyle(color: AppColors.muted, fontSize: 12)),
              ),
            )
          else
            ..._friends.map((f) => Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: PlayerRow(
                    player: f,
                    // Если группа уже собрана — кнопок "Позвать" нет
                    // (раздел 5.1, п.8).
                    trailing: inParty
                        ? null
                        : TextButton(
                            onPressed: _busy ? null : () => _call(f),
                            child: const Text('Позвать', style: TextStyle(color: AppColors.gold, fontSize: 11)),
                          ),
                  ),
                )),
        ],
      ),
    );
  }
}

/// Панель «ГРУППА» — аватары участников и кнопка «Покинуть».
class _PartyPanel extends StatelessWidget {
  final List<PlayerRef> members;
  final bool busy;
  final VoidCallback onLeave;

  const _PartyPanel({required this.members, required this.busy, required this.onLeave});

  @override
  Widget build(BuildContext context) {
    return ChPanel(
      borderColor: AppColors.gold,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('ГРУППА · ${members.length}/2',
              style: AppFonts.mono(fontSize: 9, weight: FontWeight.w700, color: AppColors.gold)),
          const SizedBox(height: 10),
          Row(
            children: [
              ...members.map((m) => Padding(
                    padding: const EdgeInsets.only(right: 10),
                    child: Column(
                      children: [
                        ChAvatar(name: m.username, size: 40, ringColor: AppColors.gold),
                        const SizedBox(height: 4),
                        SizedBox(
                          width: 54,
                          child: Text(
                            m.username,
                            textAlign: TextAlign.center,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: AppFonts.mono(fontSize: 8, color: AppColors.muted),
                          ),
                        ),
                      ],
                    ),
                  )),
              const Spacer(),
              TextButton(
                onPressed: busy ? null : onLeave,
                child: const Text('Покинуть', style: TextStyle(color: AppColors.danger, fontSize: 11)),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            'Групповой вход упрощён: в Состязание/Дуэль оба участника '
            'нажимают «Найти соперника» одновременно.',
            style: AppFonts.mono(fontSize: 8, color: AppColors.muted).copyWith(height: 1.5),
          ),
        ],
      ),
    );
  }
}

class _InviteCard extends StatelessWidget {
  final PlayerRef? inviter;
  final bool busy;
  final VoidCallback onAccept;
  final VoidCallback onDecline;

  const _InviteCard({
    required this.inviter,
    required this.busy,
    required this.onAccept,
    required this.onDecline,
  });

  @override
  Widget build(BuildContext context) {
    final name = inviter?.username ?? 'Игрок';
    return ChPanel(
      borderColor: AppColors.gold,
      padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 10),
      child: Row(
        children: [
          ChAvatar(name: name, size: 34, ringColor: AppColors.gold),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(name, style: AppFonts.ui(fontSize: 12)),
                Text('зовёт в группу', style: AppFonts.mono(fontSize: 9, color: AppColors.muted)),
              ],
            ),
          ),
          TextButton(
            onPressed: busy ? null : onAccept,
            child: const Text('Принять', style: TextStyle(color: AppColors.ok, fontSize: 11)),
          ),
          TextButton(
            onPressed: busy ? null : onDecline,
            child: const Text('Нет', style: TextStyle(color: AppColors.muted, fontSize: 11)),
          ),
        ],
      ),
    );
  }
}

/// Единый вид строки игрока: имя, флаг, рейтинг.
class PlayerRow extends StatelessWidget {
  final PlayerRef player;
  final Widget? leading;
  final Widget? trailing;
  final Color? borderColor;
  final Color? accent;

  const PlayerRow({
    super.key,
    required this.player,
    this.leading,
    this.trailing,
    this.borderColor,
    this.accent,
  });

  @override
  Widget build(BuildContext context) {
    final color = accent ?? AppColors.cream;
    return ChPanel(
      padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 9),
      borderColor: borderColor,
      child: Row(
        children: [
          if (leading != null) ...[leading!, const SizedBox(width: 6)],
          ChAvatar(name: player.username, size: 32, ringColor: accent ?? AppColors.lineStrong),
          const SizedBox(width: 10),
          Expanded(
            child: Row(
              children: [
                Flexible(
                  child: Text(
                    player.username,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppFonts.ui(fontSize: 12, color: color),
                  ),
                ),
                const SizedBox(width: 6),
                Text(player.flag, style: const TextStyle(fontSize: 13)),
              ],
            ),
          ),
          Text(
            '${player.rating.display}',
            style: AppFonts.mono(fontSize: 10, weight: FontWeight.w700, color: color),
          ),
          ?trailing,
        ],
      ),
    );
  }
}

// =====================================================================
// Вкладка «Рейтинг»
// =====================================================================

class _LeaderboardTab extends StatefulWidget {
  const _LeaderboardTab();

  @override
  State<_LeaderboardTab> createState() => _LeaderboardTabState();
}

class _LeaderboardTabState extends State<_LeaderboardTab> {
  List<PlayerRef> _rows = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final rows = await supabase
          .from('user_languages')
          .select('${PlayerRating.columns}, users(id, username, native_language)')
          .eq('role', 'learning')
          .eq('is_active', true)
          // Таблица лидеров идёт по league_rating (rating - 2*RD) — так
          // рекомендует сам Гликман: место в таблице должно отражать то,
          // что система про игрока уже знает, а не аванс новичку.
          .order('league_rating', ascending: false)
          .limit(50);
      final players = <PlayerRef>[];
      for (final row in rows) {
        final user = row['users'] as Map<String, dynamic>?;
        if (user == null) continue;
        players.add(PlayerRef(
          id: user['id'] as String,
          username: (user['username'] as String?) ?? 'Игрок',
          nativeLanguage: user['native_language'] as String?,
          rating: PlayerRating.fromRow(Map<String, dynamic>.from(row)),
        ));
      }
      if (!mounted) return;
      setState(() {
        _rows = players;
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_rows.isEmpty) {
      return const Center(child: Text('Рейтинг пока пуст', style: TextStyle(color: AppColors.muted, fontSize: 12)));
    }
    final myId = currentUserId;
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.separated(
        itemCount: _rows.length,
        separatorBuilder: (context, i) => const SizedBox(height: 7),
        itemBuilder: (context, i) {
          final player = _rows[i];
          final isMe = player.id == myId;
          final league = player.rating.league;
          return PlayerRow(
            player: player,
            accent: league.color,
            borderColor: isMe ? AppColors.gold : null,
            leading: SizedBox(
              width: 20,
              child: Text(
                '${i + 1}',
                style: AppFonts.mono(
                  fontSize: 11,
                  weight: FontWeight.w700,
                  color: isMe ? AppColors.gold : AppColors.muted,
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

// =====================================================================
// Вкладка «Поиск»
// =====================================================================

class _SearchTab extends StatefulWidget {
  const _SearchTab();

  @override
  State<_SearchTab> createState() => _SearchTabState();
}

class _SearchTabState extends State<_SearchTab> {
  final _controller = TextEditingController();
  List<PlayerRef> _results = [];
  final Set<String> _added = {};

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _search(String query) async {
    if (query.trim().length < 2) {
      setState(() => _results = []);
      return;
    }
    try {
      final rows = await supabase
          .from('users')
          .select('id')
          .ilike('username', '%${query.trim()}%')
          .neq('id', currentUserId)
          .limit(20);
      final players = await loadPlayers(rows.map((r) => r['id'] as String));
      if (!mounted) return;
      setState(() => _results = players.values.toList());
    } catch (e) {
      debugPrint('friend search failed: $e');
    }
  }

  Future<void> _add(String friendId) async {
    try {
      await supabase.from('friendships').insert({
        'user_id': currentUserId,
        'friend_id': friendId,
        'status': 'accepted',
      });
      if (mounted) setState(() => _added.add(friendId));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Не удалось добавить: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ChPanel(
          padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 4),
          child: TextField(
            controller: _controller,
            onChanged: _search,
            style: const TextStyle(color: AppColors.cream, fontSize: 13),
            decoration: const InputDecoration(
              border: InputBorder.none,
              hintText: 'Ник игрока…',
              hintStyle: TextStyle(color: AppColors.muted, fontSize: 12),
              prefixIcon: Icon(Icons.search, color: AppColors.muted, size: 18),
            ),
          ),
        ),
        const SizedBox(height: 12),
        Expanded(
          child: ListView.separated(
            itemCount: _results.length,
            separatorBuilder: (context, i) => const SizedBox(height: 8),
            itemBuilder: (context, i) {
              final player = _results[i];
              final added = _added.contains(player.id);
              return PlayerRow(
                player: player,
                trailing: TextButton(
                  onPressed: added ? null : () => _add(player.id),
                  child: Text(
                    added ? 'Добавлено' : '+ Добавить',
                    style: TextStyle(color: added ? AppColors.muted : AppColors.gold, fontSize: 10),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}
