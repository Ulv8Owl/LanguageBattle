/// Строки интерфейса на русском и английском.
///
/// Почему один класс с полями, а не карта `Map<String, String>` и не
/// сгенерированные .arb: поля проверяет компилятор. Добавив строку в
/// [AppStrings.ru] и забыв про [AppStrings.en], проект не соберётся — а
/// именно это и требуется, чтобы английский не отставал от русского по
/// мере роста игры. С картой забытый ключ обнаружился бы только на экране
/// у игрока, пустой строкой.
///
/// Строки с подстановкой объявлены функциями, а не шаблонами с {0}: так
/// у переводчика на руках порядок и смысл аргументов, а не догадки.
///
/// ЧТО ЛОКАЛИЗОВАНО. Пока — экраны, добавленные вместе с переключателем
/// языка: Настройки, выбор уровня CEFR и проверка уровня. Остальные экраны
/// (Арена, бой, магазин) остаются русскими до отдельной задачи; добавляя
/// новый элемент интерфейса, строку сюда добавлять ОБЯЗАТЕЛЬНО — на обоих
/// языках.
class AppStrings {
  // --- общее ---------------------------------------------------------
  final String cancel;
  final String close;
  final String retry;
  final String delete;
  final String applyAction;
  final String continueAction;

  // --- настройки -----------------------------------------------------
  final String settingsTitle;
  final String sectionInterface;
  final String sectionTraining;
  final String sectionDebug;
  final String sectionNotifications;
  final String sectionPrivacy;
  final String sectionAbout;
  final String sectionAccount;

  final String interfaceLanguage;
  final String nativeLanguages;
  final String cardsPerTraining;
  final String ratingAndLeague;
  final String matchNotifications;
  final String hideFromLeaderboard;
  final String blockedPlayers;
  final String myReports;
  final String buildVersion;
  final String versionCopied;
  final String signOut;

  final String deleteAccount;
  final String deleteAccountConfirmTitle;
  final String deleteAccountConfirmBody;
  final String deleteAccountConfirmAction;
  final String deleteAccountDone;
  final String Function(Object error) deleteAccountFailed;

  // --- выбор уровня CEFR ---------------------------------------------
  final String levelSelectTitle;
  final String levelSelectIntro;
  final String levelSelectAction;
  final String Function(Object error) levelSelectFailed;

  /// Название уровня: A0 — «Начинающий с нуля» / «Beginner».
  final String Function(String code) levelName;

  // --- проверка уровня -----------------------------------------------
  final String levelCheckTitle;
  final String Function(String level) levelCheckIntro;
  final String levelCheckStart;
  final String levelCheckPassedTitle;
  final String Function(int percent) levelCheckPassedBody;
  final String levelCheckFailedTitle;
  final String Function(int percent) levelCheckFailedBody;
  final String levelCheckRetry;
  final String levelCheckPickAnother;
  final String levelCheckToArena;

  const AppStrings({
    required this.cancel,
    required this.close,
    required this.retry,
    required this.delete,
    required this.applyAction,
    required this.continueAction,
    required this.settingsTitle,
    required this.sectionInterface,
    required this.sectionTraining,
    required this.sectionDebug,
    required this.sectionNotifications,
    required this.sectionPrivacy,
    required this.sectionAbout,
    required this.sectionAccount,
    required this.interfaceLanguage,
    required this.nativeLanguages,
    required this.cardsPerTraining,
    required this.ratingAndLeague,
    required this.matchNotifications,
    required this.hideFromLeaderboard,
    required this.blockedPlayers,
    required this.myReports,
    required this.buildVersion,
    required this.versionCopied,
    required this.signOut,
    required this.deleteAccount,
    required this.deleteAccountConfirmTitle,
    required this.deleteAccountConfirmBody,
    required this.deleteAccountConfirmAction,
    required this.deleteAccountDone,
    required this.deleteAccountFailed,
    required this.levelSelectTitle,
    required this.levelSelectIntro,
    required this.levelSelectAction,
    required this.levelSelectFailed,
    required this.levelName,
    required this.levelCheckTitle,
    required this.levelCheckIntro,
    required this.levelCheckStart,
    required this.levelCheckPassedTitle,
    required this.levelCheckPassedBody,
    required this.levelCheckFailedTitle,
    required this.levelCheckFailedBody,
    required this.levelCheckRetry,
    required this.levelCheckPickAnother,
    required this.levelCheckToArena,
  });

  static const AppStrings ru = AppStrings(
    cancel: 'Отмена',
    close: 'Закрыть',
    retry: 'Ещё раз',
    delete: 'Удалить',
    applyAction: 'Применить',
    continueAction: 'Продолжить',
    settingsTitle: 'Настройки',
    sectionInterface: 'ИНТЕРФЕЙС',
    sectionTraining: 'ТРЕНИРОВКА',
    sectionDebug: 'ОТЛАДКА',
    sectionNotifications: 'УВЕДОМЛЕНИЯ',
    sectionPrivacy: 'ПРИВАТНОСТЬ',
    sectionAbout: 'О ПРИЛОЖЕНИИ',
    sectionAccount: 'АККАУНТ',
    interfaceLanguage: 'Язык интерфейса',
    nativeLanguages: 'Родные языки',
    cardsPerTraining: 'Карточек за тренировку',
    ratingAndLeague: 'Рейтинг и лига',
    matchNotifications: 'Уведомления о матчах',
    hideFromLeaderboard: 'Скрыть меня из рейтинга',
    blockedPlayers: 'Заблокированные игроки',
    myReports: 'Мои жалобы',
    buildVersion: 'Версия сборки',
    versionCopied: 'Версия скопирована',
    signOut: 'Выйти из аккаунта',
    deleteAccount: 'Удалить аккаунт',
    deleteAccountConfirmTitle: 'Удалить аккаунт?',
    deleteAccountConfirmBody:
        'Профиль, рейтинг, купленные наборы слов, прогресс и история матчей '
        'будут удалены безвозвратно. Отменить это будет нельзя.',
    deleteAccountConfirmAction: 'Удалить навсегда',
    deleteAccountDone: 'Аккаунт удалён',
    deleteAccountFailed: _ruDeleteAccountFailed,
    levelSelectTitle: 'Уровень владения языком',
    levelSelectIntro:
        'Оцени свой уровень — от него зависит сложность фраз и с какого '
        'рейтинга ты начнёшь. Дальше будет короткая проверка: если уровень '
        'подтвердится, он и останется.',
    levelSelectAction: 'Пройти проверку',
    levelSelectFailed: _ruLevelSelectFailed,
    levelName: _ruLevelName,
    levelCheckTitle: 'Проверка уровня',
    levelCheckIntro: _ruLevelCheckIntro,
    levelCheckStart: 'Начать проверку',
    levelCheckPassedTitle: 'Уровень подтверждён',
    levelCheckPassedBody: _ruLevelCheckPassedBody,
    levelCheckFailedTitle: 'Уровень не подтверждён',
    levelCheckFailedBody: _ruLevelCheckFailedBody,
    levelCheckRetry: 'Попробовать ещё раз',
    levelCheckPickAnother: 'Выбрать другой уровень',
    levelCheckToArena: 'В игру',
  );

  static const AppStrings en = AppStrings(
    cancel: 'Cancel',
    close: 'Close',
    retry: 'Try again',
    delete: 'Delete',
    applyAction: 'Apply',
    continueAction: 'Continue',
    settingsTitle: 'Settings',
    sectionInterface: 'INTERFACE',
    sectionTraining: 'TRAINING',
    sectionDebug: 'DEBUG',
    sectionNotifications: 'NOTIFICATIONS',
    sectionPrivacy: 'PRIVACY',
    sectionAbout: 'ABOUT',
    sectionAccount: 'ACCOUNT',
    interfaceLanguage: 'Interface language',
    nativeLanguages: 'Native languages',
    cardsPerTraining: 'Cards per training',
    ratingAndLeague: 'Rating and league',
    matchNotifications: 'Match notifications',
    hideFromLeaderboard: 'Hide me from the leaderboard',
    blockedPlayers: 'Blocked players',
    myReports: 'My reports',
    buildVersion: 'Build version',
    versionCopied: 'Version copied',
    signOut: 'Sign out',
    deleteAccount: 'Delete account',
    deleteAccountConfirmTitle: 'Delete account?',
    deleteAccountConfirmBody:
        'Your profile, rating, purchased word packs, progress and match '
        'history will be deleted permanently. This cannot be undone.',
    deleteAccountConfirmAction: 'Delete permanently',
    deleteAccountDone: 'Account deleted',
    deleteAccountFailed: _enDeleteAccountFailed,
    levelSelectTitle: 'Your language level',
    levelSelectIntro:
        'Pick your level — it sets how hard the phrases are and what rating '
        'you start from. Next comes a short check: if the level holds up, '
        'it stays.',
    levelSelectAction: 'Take the check',
    levelSelectFailed: _enLevelSelectFailed,
    levelName: _enLevelName,
    levelCheckTitle: 'Level check',
    levelCheckIntro: _enLevelCheckIntro,
    levelCheckStart: 'Start the check',
    levelCheckPassedTitle: 'Level confirmed',
    levelCheckPassedBody: _enLevelCheckPassedBody,
    levelCheckFailedTitle: 'Level not confirmed',
    levelCheckFailedBody: _enLevelCheckFailedBody,
    levelCheckRetry: 'Try again',
    levelCheckPickAnother: 'Pick another level',
    levelCheckToArena: 'Play',
  );
}

// Функции-поля должны быть константными выражениями, поэтому они вынесены
// на верхний уровень: замыкание внутри const-конструктора не сослать.

String _ruDeleteAccountFailed(Object e) => 'Не удалось удалить аккаунт: $e';
String _enDeleteAccountFailed(Object e) => 'Could not delete the account: $e';

String _ruLevelSelectFailed(Object e) => 'Не удалось сохранить уровень: $e';
String _enLevelSelectFailed(Object e) => 'Could not save the level: $e';

String _ruLevelName(String code) => switch (code) {
      'a0' => 'Начинающий с нуля',
      'a1' => 'Начальный',
      'a2' => 'Продолжающий',
      'b1' => 'Средний',
      'b2' => 'Продвинутый',
      'c1' => 'Высокий',
      'c2' => 'Профессиональный',
      _ => code.toUpperCase(),
    };

String _enLevelName(String code) => switch (code) {
      'a0' => 'Beginner',
      'a1' => 'Elementary',
      'a2' => 'Pre-intermediate',
      'b1' => 'Intermediate',
      'b2' => 'Upper-intermediate',
      'c1' => 'Advanced',
      'c2' => 'Proficiency',
      _ => code.toUpperCase(),
    };

String _ruLevelCheckIntro(String level) =>
    'Несколько фраз уровня $level: переведи их вслух, как в обычной игре. '
    'Чтобы уровень подтвердился, нужно ответить правильно не меньше чем '
    'на 60%.';
String _enLevelCheckIntro(String level) =>
    'A few $level phrases: translate them out loud, just like in a normal '
    'round. To confirm the level you need at least 60% correct.';

String _ruLevelCheckPassedBody(int percent) =>
    'Правильных ответов: $percent%. Уровень принят — начинаем с него.';
String _enLevelCheckPassedBody(int percent) =>
    'You got $percent% right. Level accepted — that is where you start.';

String _ruLevelCheckFailedBody(int percent) =>
    'Правильных ответов: $percent%, а нужно не меньше 60%. Попробуйте ещё '
    'раз или выберите другой уровень владения языком.';
String _enLevelCheckFailedBody(int percent) =>
    'You got $percent% right, and at least 60% is needed. Try again or pick '
    'another language level.';
