import 'package:flutter/material.dart';

import '../../core/supabase_client.dart';
import '../../core/theme.dart';
import '../../widgets/lexarena_widgets.dart';

const _languageFlags = {'en': '🇬🇧', 'es': '🇪🇸', 'ru': '🇷🇺'};

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  Map<String, dynamic>? _profile;
  Map<String, dynamic>? _learning;
  int _played = 0;
  int _winPct = 0;
  int _streak = 0;
  List<Map<String, dynamic>> _inventory = [];
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
      final profile = await supabase.from('users').select().eq('id', uid).maybeSingle();
      final learning = await supabase
          .from('user_languages')
          .select()
          .eq('user_id', uid)
          .eq('role', 'learning')
          .limit(1)
          .maybeSingle();
      final asA = await supabase.from('matches').select().eq('player_a_id', uid).eq('status', 'completed');
      final asB = await supabase.from('matches').select().eq('player_b_id', uid).eq('status', 'completed');
      final all = [...asA, ...asB]
        ..sort((a, b) => (b['completed_at'] as String? ?? '').compareTo(a['completed_at'] as String? ?? ''));

      final played = all.length;
      final wins = all.where((m) => m['winner_id'] == uid).length;
      var streak = 0;
      for (final m in all) {
        if (m['winner_id'] == uid) {
          streak++;
        } else {
          break;
        }
      }

      final inventory = await supabase
          .from('user_inventory')
          .select('item_id, cosmetic_items(*)')
          .eq('user_id', uid);

      if (!mounted) return;
      setState(() {
        _profile = profile;
        _learning = learning;
        _played = played;
        _winPct = played == 0 ? 0 : ((wins / played) * 100).round();
        _streak = streak;
        _inventory = List<Map<String, dynamic>>.from(inventory);
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());

    final username = (_profile?['username'] as String?) ?? 'Игрок';
    final native = (_profile?['native_language'] as String?) ?? '?';
    final target = (_learning?['language_code'] as String?) ?? '?';
    final elo = (_learning?['elo'] as int?) ?? 1000;

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Row(
            children: [
              LxAvatar(name: username, size: 58, ringColor: AppColors.gold),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(username, style: AppFonts.ui(fontSize: 16, weight: FontWeight.w800)),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        const Icon(Icons.emoji_events, size: 14, color: AppColors.gold),
                        const SizedBox(width: 5),
                        Text('$elo ELO', style: AppFonts.mono(fontSize: 10, weight: FontWeight.w700, color: AppColors.gold)),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(child: _StatTile(value: '$_played', label: 'боёв')),
              const SizedBox(width: 8),
              Expanded(child: _StatTile(value: '$_winPct%', label: 'побед', color: AppColors.cyan)),
              const SizedBox(width: 8),
              Expanded(child: _StatTile(value: '🔥$_streak', label: 'серия', color: AppColors.ember)),
            ],
          ),
          const SizedBox(height: 18),
          Text('ЯЗЫКОВАЯ ПАРА', style: AppFonts.mono(fontSize: 9, weight: FontWeight.w700, color: AppColors.gold)),
          const SizedBox(height: 8),
          LxPanel(
            padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 9),
            child: Text(
              '${_languageFlags[native] ?? '🏳'} → ${_languageFlags[target] ?? '🏳'}',
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
            ),
          ),
          const SizedBox(height: 18),
          Text('ИНВЕНТАРЬ', style: AppFonts.mono(fontSize: 9, weight: FontWeight.w700, color: AppColors.gold)),
          const SizedBox(height: 8),
          if (_inventory.isEmpty)
            const Text('Пока пусто — загляните в Магазин.', style: TextStyle(color: AppColors.muted, fontSize: 12))
          else
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: _inventory.map((row) {
                final item = row['cosmetic_items'] as Map<String, dynamic>?;
                final equipped = item?['id'] == _profile?['equipped_frame_id'] || item?['id'] == _profile?['equipped_emote_id'];
                return Container(
                  width: 64,
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    border: Border.all(color: equipped ? AppColors.gold : AppColors.line),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Column(
                    children: [
                      Icon(
                        item?['type'] == 'emote' ? Icons.emoji_emotions : Icons.circle_outlined,
                        color: AppColors.gold,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        (item?['name'] as String?) ?? '',
                        textAlign: TextAlign.center,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 8, color: AppColors.muted),
                      ),
                    ],
                  ),
                );
              }).toList(),
            ),
        ],
      ),
    );
  }
}

class _StatTile extends StatelessWidget {
  final String value;
  final String label;
  final Color color;

  const _StatTile({required this.value, required this.label, this.color = AppColors.cream});

  @override
  Widget build(BuildContext context) {
    return LxPanel(
      padding: const EdgeInsets.symmetric(vertical: 11),
      child: Column(
        children: [
          Text(value, style: AppFonts.mono(fontSize: 15, weight: FontWeight.w700, color: color)),
          const SizedBox(height: 2),
          Text(label, style: const TextStyle(fontSize: 8, color: AppColors.muted)),
        ],
      ),
    );
  }
}
