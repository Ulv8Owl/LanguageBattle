import 'package:flutter/material.dart';

import '../../core/supabase_client.dart';
import '../../core/theme.dart';
import '../../widgets/lexarena_widgets.dart';

/// Друзья/Рейтинг/Поиск (раздел 5.1, п.8). Упрощение относительно спеки:
/// добавление в друзья сразу принимается (status='accepted'), без отдельного
/// экрана "входящие заявки" — полноценный флоу запрос/подтверждение можно
/// добавить позже без изменения схемы.
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
          LxTabBar(
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

class _FriendsListTab extends StatefulWidget {
  const _FriendsListTab();

  @override
  State<_FriendsListTab> createState() => _FriendsListTabState();
}

class _FriendsListTabState extends State<_FriendsListTab> {
  List<Map<String, dynamic>> _friends = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final uid = currentUserId;
    try {
      final asUser = await supabase.from('friendships').select().eq('user_id', uid).eq('status', 'accepted');
      final asFriend = await supabase.from('friendships').select().eq('friend_id', uid).eq('status', 'accepted');
      final ids = <String>{
        for (final r in asUser) r['friend_id'] as String,
        for (final r in asFriend) r['user_id'] as String,
      };
      List<Map<String, dynamic>> friends = [];
      if (ids.isNotEmpty) {
        final rows = await supabase.from('users').select('id, username').inFilter('id', ids.toList());
        friends = List<Map<String, dynamic>>.from(rows);
      }
      if (!mounted) return;
      setState(() {
        _friends = friends;
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_friends.isEmpty) {
      return const Center(child: Text('Пока нет друзей — найдите их во вкладке «Поиск».', style: TextStyle(color: AppColors.muted)));
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.separated(
        itemCount: _friends.length,
        separatorBuilder: (context, i) => const SizedBox(height: 8),
        itemBuilder: (context, i) {
          final f = _friends[i];
          return LxPanel(
            padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 9),
            child: Row(
              children: [
                LxAvatar(name: (f['username'] as String?) ?? '?', size: 34),
                const SizedBox(width: 10),
                Expanded(child: Text((f['username'] as String?) ?? '', style: AppFonts.ui(fontSize: 12))),
                TextButton(
                  onPressed: () => ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Приглашения на бой появятся вместе с матчмейкингом')),
                  ),
                  child: const Text('Позвать', style: TextStyle(color: AppColors.gold, fontSize: 11)),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _LeaderboardTab extends StatefulWidget {
  const _LeaderboardTab();

  @override
  State<_LeaderboardTab> createState() => _LeaderboardTabState();
}

class _LeaderboardTabState extends State<_LeaderboardTab> {
  List<Map<String, dynamic>> _rows = [];
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
          .select('elo, users(id, username)')
          .eq('role', 'learning')
          .order('elo', ascending: false)
          .limit(50);
      if (!mounted) return;
      setState(() {
        _rows = List<Map<String, dynamic>>.from(rows);
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    final myId = currentUserId;
    return ListView.separated(
      itemCount: _rows.length,
      separatorBuilder: (context, i) => const SizedBox(height: 7),
      itemBuilder: (context, i) {
        final row = _rows[i];
        final user = row['users'] as Map<String, dynamic>?;
        final isMe = user?['id'] == myId;
        return LxPanel(
          padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 9),
          borderColor: isMe ? AppColors.gold : AppColors.line,
          child: Row(
            children: [
              SizedBox(
                width: 20,
                child: Text('${i + 1}', style: AppFonts.mono(fontSize: 11, weight: FontWeight.w700, color: isMe ? AppColors.gold : AppColors.muted)),
              ),
              const SizedBox(width: 6),
              LxAvatar(name: (user?['username'] as String?) ?? '?', size: 28),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  isMe ? 'Ты' : ((user?['username'] as String?) ?? ''),
                  style: AppFonts.ui(fontSize: 11, color: isMe ? AppColors.gold : AppColors.cream),
                ),
              ),
              Text('${row['elo']}', style: AppFonts.mono(fontSize: 10, weight: FontWeight.w700, color: isMe ? AppColors.gold : AppColors.cream)),
            ],
          ),
        );
      },
    );
  }
}

class _SearchTab extends StatefulWidget {
  const _SearchTab();

  @override
  State<_SearchTab> createState() => _SearchTabState();
}

class _SearchTabState extends State<_SearchTab> {
  final _controller = TextEditingController();
  List<Map<String, dynamic>> _results = [];
  final Set<String> _added = {};

  Future<void> _search(String query) async {
    if (query.trim().length < 2) {
      setState(() => _results = []);
      return;
    }
    try {
      final rows = await supabase
          .from('users')
          .select('id, username')
          .ilike('username', '%${query.trim()}%')
          .neq('id', currentUserId)
          .limit(20);
      if (!mounted) return;
      setState(() => _results = List<Map<String, dynamic>>.from(rows));
    } catch (_) {}
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
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        LxPanel(
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
              final r = _results[i];
              final id = r['id'] as String;
              final added = _added.contains(id);
              return LxPanel(
                padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 9),
                child: Row(
                  children: [
                    LxAvatar(name: (r['username'] as String?) ?? '?', size: 32),
                    const SizedBox(width: 10),
                    Expanded(child: Text((r['username'] as String?) ?? '', style: AppFonts.ui(fontSize: 11))),
                    TextButton(
                      onPressed: added ? null : () => _add(id),
                      child: Text(added ? 'Добавлено' : '+ Добавить', style: TextStyle(color: added ? AppColors.muted : AppColors.gold, fontSize: 10)),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}
