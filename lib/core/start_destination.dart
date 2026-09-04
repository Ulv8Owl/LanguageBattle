import 'supabase_client.dart';

/// Куда вести игрока после того, как он оказался авторизован.
///
/// Один ответ на весь проект. Раньше этот выбор был написан ДВАЖДЫ — в
/// SplashGate (холодный старт) и в LoginScreen (вход по паролю), — и они
/// разошлись ровно так, как расходятся любые две копии: экран уровня CEFR
/// добавили в SplashGate и забыли в LoginScreen. Дыру было видно не сразу:
/// игрок доходил до выбора уровня, выходил в меню входа, логинился заново —
/// и попадал прямо в игру, ни разу не подтвердив уровень.
///
/// Порядок проверок здесь и есть порядок шагов регистрации, и каждый шаг
/// НЕЛЬЗЯ пропустить, закрыв приложение: пока шаг не пройден, вход в
/// аккаунт приводит игрока обратно на него.
enum StartDestination {
  /// Профиля с языковой парой ещё нет — первый шаг регистрации.
  onboarding('/onboarding'),

  /// Пара есть, но уровень CEFR не подтверждён.
  levelSelect('/level-select'),

  /// Всё пройдено — в игру.
  arena('/arena');

  final String route;
  const StartDestination(this.route);
}

/// Спрашивает у базы, на каком шаге стоит игрок.
///
/// При ошибке (нет сети, пустой ответ) возвращает [StartDestination.onboarding]:
/// повторно пройти онбординг неприятно, но не разрушительно, а вот пустить
/// в игру аккаунт, про который ничего не известно, — хуже.
Future<StartDestination> resolveStartDestination() async {
  try {
    final rows = await supabase
        .from('user_languages')
        .select('id, placement_done')
        .eq('user_id', currentUserId)
        .eq('role', 'learning')
        .limit(1);
    if (rows.isEmpty) return StartDestination.onboarding;
    // placement_done приходит false у пар, заведённых после миграции 0028 и
    // ещё не подтверждённых. Отсутствие поля (старый клиент, урезанная
    // выборка) считаем пройденным: у всех существовавших до 0028 пар
    // миграция проставила true.
    final done = rows.first['placement_done'] as bool? ?? true;
    return done ? StartDestination.arena : StartDestination.levelSelect;
  } catch (_) {
    return StartDestination.onboarding;
  }
}
