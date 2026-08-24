import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/supabase_client.dart';
import '../../core/theme.dart';

class ArenaScreen extends StatefulWidget {
  const ArenaScreen({super.key});

  @override
  State<ArenaScreen> createState() => _ArenaScreenState();
}

class _ArenaScreenState extends State<ArenaScreen> {
  Map<String, dynamic>? _profile;
  List<Map<String, dynamic>> _matches = [];
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
      final profile =
          await supabase.from('users').select().eq('id', uid).maybeSingle();
      final asPlayerA = await supabase
          .from('matches')
          .select()
          .eq('player_a_id', uid)
          .inFilter('status', ['in_progress', 'completed']);
      final asPlayerB = await supabase
          .from('matches')
          .select()
          .eq('player_b_id', uid)
          .inFilter('status', ['in_progress', 'completed']);
      final all = [...asPlayerA, ...asPlayerB];
      all.sort((a, b) => (b['created_at'] as String).compareTo(a['created_at'] as String));
      if (!mounted) return;
      setState(() {
        _profile = profile;
        _matches = all;
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _signOut() async {
    await supabase.auth.signOut();
    if (mounted) context.go('/login');
  }

  void _showModeInfo(String title, String description) {
    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.navy2,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) => Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
            const SizedBox(height: 12),
            Text(description, style: const TextStyle(color: AppColors.muted)),
            const SizedBox(height: 20),
            const Text(
              'Реальный матчмейкинг появится в Фазе 3. Сейчас тестовые матчи '
              'создаются вручную через Supabase Studio (см. supabase/README.md) '
              'и появляются в списке "Активные бои" ниже.',
              style: TextStyle(color: AppColors.muted, fontSize: 13),
            ),
            const SizedBox(height: 20),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Понятно'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Row(
            children: [
              const CircleAvatar(radius: 22, child: Icon(Icons.person)),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      (_profile?['username'] as String?) ?? 'Игрок',
                      style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
                    ),
                    const Text('LVL 1', style: TextStyle(color: AppColors.gold, fontSize: 11)),
                  ],
                ),
              ),
              IconButton(
                onPressed: _signOut,
                icon: const Icon(Icons.logout),
                tooltip: 'Выйти',
              ),
            ],
          ),
          const SizedBox(height: 24),
          _ModeRow(
            title: 'Одиночная Игра',
            onTap: () => context.push('/training'),
          ),
          const SizedBox(height: 10),
          _ModeRow(
            title: 'Состязание',
            onTap: () => _showModeInfo(
              'Состязание',
              'PvP против любого игрока с тем же изучаемым языком. 10 раундов, один голосовой за раунд.',
            ),
          ),
          const SizedBox(height: 10),
          _ModeRow(
            title: 'Дуэль',
            flagship: true,
            onTap: () => _showModeInfo(
              'Дуэль',
              'PvP против носителя изучаемого языка (обратная пара). 10 раундов, два голосовых за раунд.',
            ),
          ),
          const SizedBox(height: 28),
          const Text('Активные бои', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
          const SizedBox(height: 12),
          if (_matches.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: Text(
                'Пока нет матчей. Попросите создать тестовый матч через Supabase Studio.',
                style: TextStyle(color: AppColors.muted),
              ),
            )
          else
            ..._matches.map((m) => _MatchRow(match: m)),
        ],
      ),
    );
  }
}

class _ModeRow extends StatelessWidget {
  final String title;
  final bool flagship;
  final VoidCallback onTap;

  const _ModeRow({required this.title, required this.onTap, this.flagship = false});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: flagship ? AppColors.gold : Colors.white24, width: 1.5),
          color: flagship ? AppColors.gold.withValues(alpha: 0.10) : Colors.white.withValues(alpha: 0.03),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              title,
              style: TextStyle(
                fontWeight: FontWeight.w700,
                fontSize: 16,
                color: flagship ? AppColors.gold : AppColors.cream,
              ),
            ),
            Icon(Icons.chevron_right, color: flagship ? AppColors.gold : AppColors.muted),
          ],
        ),
      ),
    );
  }
}

class _MatchRow extends StatelessWidget {
  final Map<String, dynamic> match;

  const _MatchRow({required this.match});

  @override
  Widget build(BuildContext context) {
    final status = match['status'] as String;
    final completed = status == 'completed';
    return Card(
      color: AppColors.navy2,
      margin: const EdgeInsets.only(bottom: 10),
      child: ListTile(
        title: Text(match['game_mode'] == 'native_duel' ? 'Дуэль' : 'Состязание'),
        subtitle: Text(completed ? 'Завершён' : 'В процессе — раунды идут'),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => context.push(
          completed ? '/battle/${match['id']}/results' : '/battle/${match['id']}',
        ),
      ),
    );
  }
}
