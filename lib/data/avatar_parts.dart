/// Каталог частей аватара — что из чего собирается.
///
/// СПРАЙТЫ ЛЕЖАТ В assets/avatar, ИСХОДНИКИ — В content/Avatar. Все они
/// одного размера (130x130) и уже совмещены между собой: глаза нарисованы
/// там, где у лица глаза. Поэтому сборка — это просто стопка картинок в
/// нужном порядке, без единой координаты в коде. Стоит художнику сдвинуть
/// деталь на своём слое — и она сдвинется в игре, править Dart не придётся.
///
/// КАК ДОБАВИТЬ ВАРИАНТ:
///   1. положить PNG 130x130 в content/Avatar и скопировать в assets/avatar;
///   2. дописать [AvatarPart] в нужный слот ниже.
/// Больше нигде ничего менять не нужно: и редактор, и все аватары в игре
/// читают этот список.
library;

/// Один выбираемый вариант: то, что игрок видит плиткой в редакторе.
class AvatarPart {
  /// Идентификатор, который уходит в базу. МЕНЯТЬ НЕЛЬЗЯ: он записан в
  /// users.equipped_avatar у всех, кто уже собрал себе аватар.
  final String id;

  final String title;

  /// Слои этого варианта снизу вверх. Их может быть больше одного: тело —
  /// это шея и плечи, и выбирать их порознь незачем.
  final List<String> layers;

  const AvatarPart({required this.id, required this.title, required this.layers});
}

/// Слот — одна строка выбора в редакторе. Порядок слотов в [avatarSlots] и
/// есть порядок отрисовки: что ниже в списке, то рисуется поверх.
class AvatarSlot {
  final String id;
  final String title;

  /// Можно ли обойтись без этой части. Лицо и тело обязательны — без них
  /// это не портрет, а набор бровей в воздухе.
  final bool optional;

  final List<AvatarPart> parts;

  const AvatarSlot({
    required this.id,
    required this.title,
    required this.parts,
    this.optional = true,
  });
}

const String _dir = 'assets/avatar';

/// Фон — общий для всех, выбирать его пока не из чего.
const String avatarBackground = '$_dir/Background.png';

/// Слоты в порядке отрисовки: тело внизу, губы сверху.
const List<AvatarSlot> avatarSlots = [
  AvatarSlot(
    id: 'body',
    title: 'Телосложение',
    optional: false,
    parts: [
      AvatarPart(
        id: 'male',
        title: 'Мужское',
        layers: ['$_dir/Male-Neck.png', '$_dir/Male-Brest.png'],
      ),
      AvatarPart(
        id: 'female',
        title: 'Женское',
        layers: ['$_dir/Female-Neck.png', '$_dir/Female-Brest.png'],
      ),
    ],
  ),
  AvatarSlot(
    id: 'face',
    title: 'Лицо',
    optional: false,
    parts: [
      AvatarPart(id: 'face1', title: 'Лицо', layers: ['$_dir/Face1.png']),
    ],
  ),
  AvatarSlot(
    id: 'brows',
    title: 'Брови',
    parts: [
      AvatarPart(id: 'brows1', title: 'Прямые', layers: ['$_dir/brows.png']),
    ],
  ),
  AvatarSlot(
    id: 'eyes',
    title: 'Глаза',
    optional: false,
    parts: [
      AvatarPart(id: 'eyes1', title: 'Тёмные', layers: ['$_dir/eyes-1.png']),
      AvatarPart(id: 'eyes2', title: 'Светлые', layers: ['$_dir/eyes-2.png']),
    ],
  ),
  AvatarSlot(
    id: 'nose',
    title: 'Нос',
    parts: [
      AvatarPart(id: 'nose2', title: 'Прямой', layers: ['$_dir/nose-2.png']),
    ],
  ),
  AvatarSlot(
    id: 'lips',
    title: 'Губы',
    parts: [
      AvatarPart(id: 'lips2', title: 'Обычные', layers: ['$_dir/Lips2.png']),
    ],
  ),
];

/// С чего начинает тот, кто ещё ни разу не открывал редактор.
///
/// Не пустота: пустой редактор показывал бы один фон, и было бы непонятно,
/// собирается ли что-нибудь вообще.
Map<String, String> defaultAvatar() => {
      for (final slot in avatarSlots)
        if (!slot.optional || slot.parts.isNotEmpty) slot.id: slot.parts.first.id,
    };

/// Слои выбранного аватара снизу вверх — ровно то, что рисует виджет.
///
/// Неизвестные слоты и варианты молча пропускаются: набор спрайтов растёт и
/// меняется, а в базе у игрока может лежать вариант из прошлой версии.
/// Падать из-за этого нельзя — аватар это украшение, а не механика.
List<String> avatarLayers(Map<String, String> equipped) {
  final out = <String>[avatarBackground];
  for (final slot in avatarSlots) {
    final chosen = equipped[slot.id];
    if (chosen == null) continue;
    for (final part in slot.parts) {
      if (part.id == chosen) out.addAll(part.layers);
    }
  }
  return out;
}

/// Есть ли что показывать, кроме фона. По этому признаку виджет решает,
/// рисовать портрет или прежнюю заглушку с буквой имени.
bool hasAvatar(Map<String, String> equipped) => avatarLayers(equipped).length > 1;

/// Разбор users.equipped_avatar. Значение свободной формы (jsonb), и всё
/// лишнее здесь отсекается: в игру попадают только строки.
Map<String, String> avatarFromJson(dynamic raw) {
  final out = <String, String>{};
  if (raw is Map) {
    raw.forEach((key, value) {
      if (key is String && value is String) out[key] = value;
    });
  }
  return out;
}
