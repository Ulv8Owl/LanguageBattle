import 'package:flutter/foundation.dart';

/// Вкладки нижней навигации (порядок как в ArenaShell):
/// 0 Профиль · 1 Друзья · 2 Арена · 3 Магазин · 4 Награды.
class ArenaTabs {
  ArenaTabs._();

  static const profile = 0;
  static const friends = 1;
  static const arena = 2;
  static const shop = 3;
  static const rewards = 4;
}

/// Разделы Магазина: 0 Подписка · 1 Предметы.
class ShopSections {
  ShopSections._();

  static const subscription = 0;
  static const items = 1;
}

/// Экран пейволла и карточка друга должны уметь перекинуть пользователя на
/// конкретную вкладку/раздел уже существующего shell'а, не пересоздавая его.
/// Один общий notifier проще, чем протаскивать колбэки через полдерева.
final ValueNotifier<int> arenaTabRequest = ValueNotifier<int>(ArenaTabs.arena);

final ValueNotifier<int> shopSectionRequest =
    ValueNotifier<int>(ShopSections.subscription);

void openShopSubscription() {
  shopSectionRequest.value = ShopSections.subscription;
  arenaTabRequest.value = ArenaTabs.shop;
}
