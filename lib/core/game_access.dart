import 'supabase_client.dart';

/// Состояние кошелька + подписки одним снимком. Приходит из RPC
/// `sync_wallet`, который заодно досчитывает восстановленную энергию —
/// клиент энергию не считает и не начисляет сам (раздел 2.6).
class WalletState {
  final int coins;
  final int energyCurrent;
  final int energyMax;

  /// 'trial' | 'active' | 'cancelled' | 'expired'
  final String subscriptionStatus;
  final DateTime? trialEndsAt;
  final DateTime? expiresAt;

  /// Единственный признак, по которому пускать в режимы: считается на
  /// сервере (has_game_access), клиент его только отображает.
  final bool hasAccess;

  const WalletState({
    required this.coins,
    required this.energyCurrent,
    required this.energyMax,
    required this.subscriptionStatus,
    required this.trialEndsAt,
    required this.expiresAt,
    required this.hasAccess,
  });

  static const empty = WalletState(
    coins: 0,
    energyCurrent: 0,
    // Совпадает с потолком в схеме (миграция 0032). Это заглушка «до
    // ответа сервера»: показать 0/10 там, где на деле 0/50, — значит
    // соврать про запас в пять раз.
    energyMax: 50,
    subscriptionStatus: 'expired',
    trialEndsAt: null,
    expiresAt: null,
    hasAccess: false,
  );

  factory WalletState.fromJson(Map<String, dynamic> json) {
    DateTime? parse(String key) {
      final raw = json[key] as String?;
      return raw == null ? null : DateTime.tryParse(raw);
    }

    return WalletState(
      coins: (json['soft_currency'] as num?)?.toInt() ?? 0,
      energyCurrent: (json['energy_current'] as num?)?.toInt() ?? 0,
      energyMax: (json['energy_max'] as num?)?.toInt() ?? 50,
      subscriptionStatus: (json['subscription_status'] as String?) ?? 'expired',
      trialEndsAt: parse('trial_ends_at'),
      expiresAt: parse('expires_at'),
      hasAccess: json['has_access'] as bool? ?? false,
    );
  }

  bool get isTrial => subscriptionStatus == 'trial' && hasAccess;

  bool get isSubscribed => subscriptionStatus == 'active' && hasAccess;

  /// Точное оставшееся время пробного периода — для живого обратного
  /// отсчёта (TrialCountdownBanner). null, если пробного периода нет или
  /// он уже кончился. `trial_ends_at` — обычная колонка в БД, поэтому
  /// отсчёт корректен даже если игрок всё это время не заходил в
  /// приложение: тикает локально только отображение, а не сам дедлайн.
  Duration? get trialTimeLeft {
    final ends = trialEndsAt;
    if (ends == null) return null;
    final left = ends.difference(DateTime.now().toUtc());
    return left.isNegative ? null : left;
  }
}

/// Доступ к экономике: одна точка входа, чтобы экраны не дёргали RPC
/// вразнобой и не считали энергию/подписку на клиенте.
class GameAccess {
  GameAccess._();

  static Future<WalletState> sync() async {
    final result = await supabase.rpc('sync_wallet');
    if (result is Map) {
      return WalletState.fromJson(Map<String, dynamic>.from(result));
    }
    return WalletState.empty;
  }

  /// Заглушка оплаты: подписка активируется сразу, без платёжного шлюза
  /// (осознанное временное решение — Google Play Billing подключается
  /// отдельной задачей и заменит только тело RPC activate_subscription).
  static Future<void> activateSubscription() async {
    await supabase.rpc('activate_subscription');
  }
}

/// Ошибки, которые сервер отдаёт как текст исключения PostgrestException.
/// Клиент разбирает их, чтобы показать нужный экран (пейволл / нет энергии).
class ServerErrors {
  ServerErrors._();

  static bool isSubscriptionRequired(Object error) =>
      error.toString().contains('subscription_required');

  static bool isNoEnergy(Object error) => error.toString().contains('no_energy');

  static bool isInsufficientFunds(Object error) =>
      error.toString().contains('insufficient_funds');

  static bool isLeagueLocked(Object error) =>
      error.toString().contains('league_locked');
}
