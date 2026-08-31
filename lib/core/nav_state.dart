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

/// Разделы Магазина: 0 Подписка · 1 Предметы · 2 Наборы слов.
class ShopSections {
  ShopSections._();

  static const subscription = 0;
  static const items = 1;
  static const words = 2;
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

void openShopWordPacks() {
  shopSectionRequest.value = ShopSections.words;
  arenaTabRequest.value = ArenaTabs.shop;
}

/// Тренировка: какую из 6 тысяч слов открыть при заходе. -1 — "по
/// умолчанию", т.е. по текущей лиге игрока (см. FlashcardsScreen._load).
/// Плашка режима на Арене выставляет конкретный уровень перед переходом на
/// /flashcards; экран сам сбрасывает обратно в -1 после прочтения, чтобы
/// повторный заход без выбора снова показывал уровень по лиге.
final ValueNotifier<int> trainingLevelRequest = ValueNotifier<int>(-1);

/// Слова выучены/куплены наборы — считаем заново при возврате в Арену/
/// Магазин (кошелёк мог измениться после покупки набора или получения
/// монет за новые слова).
final ValueNotifier<int> wordPacksVersion = ValueNotifier<int>(0);

void notifyWordPacksChanged() {
  wordPacksVersion.value++;
}

/// Языковая пара меняется из Профиля, но её использует и Арена (рейтинг,
/// доступные режимы) — простой счётчик-нотификатор проще, чем
/// протаскивать колбэк через IndexedStack в ArenaShell.
final ValueNotifier<int> languagePairVersion = ValueNotifier<int>(0);

void notifyLanguagePairChanged() {
  languagePairVersion.value++;
}
