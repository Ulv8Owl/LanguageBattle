import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../data/avatar_parts.dart';
import 'chrolingo_widgets.dart';

/// Портрет из спрайтов — стопка картинок, ничего больше.
///
/// Все слои одного размера и уже совмещены между собой художником, поэтому
/// здесь нет ни одной координаты: сдвинуть деталь можно только в самом
/// спрайте, и это правильно — иначе рисунок и код разъезжались бы.
///
/// Рисуется БЕЗ СГЛАЖИВАНИЯ: спрайты пиксельные, и на кружке в 40 точек
/// сглаживание превращает глаза в серые пятна.
class AvatarPortrait extends StatelessWidget {
  /// Слот -> вариант, как в users.equipped_avatar.
  final Map<String, String> avatar;

  const AvatarPortrait({super.key, required this.avatar});

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        for (final layer in avatarLayers(avatar))
          Image.asset(
            layer,
            fit: BoxFit.cover,
            filterQuality: FilterQuality.none,
            // Битый или отсутствующий спрайт не должен ронять экран: аватар
            // это украшение, а не механика. Пропускаем слой и рисуем
            // остальные.
            errorBuilder: (_, _, _) => const SizedBox.shrink(),
          ),
      ],
    );
  }
}

/// Размер аватара в Профиле и на Арене.
///
/// ОДНА КОНСТАНТА НА ДВА ЭКРАНА, потому что они должны совпадать: аватар в
/// шапке Арены и аватар в Профиле — это одно и то же лицо, и разный размер
/// читался бы как разные вещи. Держать два числа значило бы однажды
/// поправить одно из них.
const double profileAvatarSize = 75;

/// Аватар, по которому открывается редактор.
///
/// Отдельной кнопки «редактор аватара» больше нет: собранный портрет и есть
/// то, на что хочется нажать, а иконка рядом только спрашивала «а это тогда
/// что?». Открывается ТОЛЬКО из Профиля и Арены — там это свой аватар;
/// нажатие на чужой в бою или в друзьях открывало бы редактор чужого лица.
class AvatarButton extends StatelessWidget {
  final String name;
  final Map<String, String> avatar;
  final Color ringColor;
  final double size;

  /// Перечитать профиль после возврата из редактора.
  final Future<void> Function() onDone;

  const AvatarButton({
    super.key,
    required this.name,
    required this.avatar,
    required this.ringColor,
    required this.onDone,
    this.size = profileAvatarSize,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: 'Редактор аватара',
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: () async {
          await context.push('/avatar');
          await onDone();
        },
        child: ChAvatar(name: name, avatar: avatar, size: size, ringColor: ringColor),
      ),
    );
  }
}
