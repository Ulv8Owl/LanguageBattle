import 'package:flutter/material.dart';

import '../core/theme.dart';

/// Значки режимов Арены, нарисованные вручную.
///
/// ПОЧЕМУ НЕ MATERIAL ICONS. Трёх нужных картинок в наборе нет вовсе:
/// колоды карт, раскрытой веером, двух микрофонов рядом и окна сообщения
/// с хвостиком. Подобранные «по смыслу» `Icons.style`, `Icons.school` и
/// `Icons.bolt` не говорили о режиме ничего — по ним нельзя было угадать,
/// что внутри.
///
/// РИСУЕМ НА СЕТКЕ 24×24, как это делает сам Material: так значок можно
/// задавать целыми числами и не пересчитывать при смене размера — холст
/// масштабируется один раз в [_ModeGlyphPainter.paint].
///
/// ДВА ЦВЕТА, А НЕ ОДИН. Карты веером и пузырь сообщения обязаны быть
/// ЗАЛИТЫ цветом подложки: иначе перекрывающиеся карты сливаются в одно
/// чёрное пятно, а внутри пузыря не видно строк. Поэтому у значка есть и
/// чернила [ink], и бумага [paper] — цвет плашки, на которой он лежит.
enum ModeGlyphKind {
  /// Колода, раскрытая веером из одной точки, — «Флэш-Карточки».
  cards,

  /// Студийный микрофон на подставке — «Голос».
  mic,

  /// Два таких же микрофона, заглядывающих навстречу друг другу из-за
  /// боковых краёв плашки, — «Голос Vs Голос».
  ///
  /// ЭТОТ ЗНАЧОК РИСУЕТСЯ ВО ВСЮ ПЛАШКУ и обрезается её краем, поэтому
  /// [ChModeIcon] обязан обрезать содержимое (`clipBehavior`). Без обрезки
  /// микрофоны вылезут за жёлтый квадрат и лягут поверх строки меню.
  micDuo,

  /// Окно сообщения со строками текста — «Общение».
  message,
}

class ModeGlyph extends StatelessWidget {
  final ModeGlyphKind kind;

  /// Сторона квадрата, в который вписан рисунок. У каждого значка своя:
  /// рисунок веера и двух микрофонов мельче деталями, и в одном размере
  /// с остальными они читаются хуже — см. вызовы в Арене.
  final double size;
  final Color ink;
  final Color paper;

  const ModeGlyph(
    this.kind, {
    super.key,
    this.size = 21,
    this.ink = Colors.black87,
    this.paper = AppColors.gold,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(painter: _ModeGlyphPainter(kind: kind, ink: ink, paper: paper)),
    );
  }
}

class _ModeGlyphPainter extends CustomPainter {
  final ModeGlyphKind kind;
  final Color ink;
  final Color paper;

  const _ModeGlyphPainter({required this.kind, required this.ink, required this.paper});

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 24, size.height / 24);
    switch (kind) {
      case ModeGlyphKind.cards:
        _cards(canvas);
      case ModeGlyphKind.mic:
        _mic(canvas);
      case ModeGlyphKind.micDuo:
        _micDuo(canvas);
      case ModeGlyphKind.message:
        _message(canvas);
    }
    canvas.restore();
  }

  Paint get _fill => Paint()
    ..color = paper
    ..style = PaintingStyle.fill
    ..isAntiAlias = true;

  Paint _line(double width) => Paint()
    ..color = ink
    ..style = PaintingStyle.stroke
    ..strokeWidth = width
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round
    ..isAntiAlias = true;

  /// Пять карт, сведённых в одну точку внизу, — так колоду держат в руке.
  ///
  /// Точка схода НИЖЕ карт, а не в их середине: веер, сведённый по центру,
  /// читается как звезда, а не как карты.
  ///
  /// А ВОТ САМ ВЕЕР ОБЯЗАН СТОЯТЬ ПО ЦЕНТРУ ПЛАШКИ. Точка схода центром
  /// не является: карты уходят от неё только ВВЕРХ, и веер, у которого по
  /// центру стоит она, висит ниже середины квадрата. Поэтому y считается
  /// от высоты веера (карта 13.2 длиной плюс разлёт нижних углов), а не
  /// ставится на глаз.
  void _cards(Canvas canvas) {
    const pivot = Offset(12, 18.3);
    const angles = [-0.60, -0.30, 0.0, 0.30, 0.60];
    final card = RRect.fromRectAndRadius(
      const Rect.fromLTRB(-3.5, -13.6, 3.5, -0.4),
      const Radius.circular(1.4),
    );
    for (final a in angles) {
      canvas.save();
      canvas.translate(pivot.dx, pivot.dy);
      canvas.rotate(a);
      canvas.drawRRect(card, _fill);
      canvas.drawRRect(card, _line(1.35));
      canvas.restore();
    }
  }

  /// Студийный микрофон: голова с решёткой, стойка и плоская подставка.
  ///
  /// ЗА ОБРАЗЕЦ ВЗЯТ РЕТРО-МИКРОФОН (тип Shure 55), упрощённый до
  /// силуэта: узнают его по ВЫСОКОЙ голове-овалу с горизонтальной
  /// решёткой и по широкой плоской подставке. Голова именно высокая —
  /// круглая читается как печать или булочка, и микрофона в ней не
  /// видно.
  ///
  /// Рисовать голову обводкой, как на плакатах, здесь нельзя: при 26
  /// точках решётка из шести щелей сливается в серую кашу. Поэтому
  /// голова ЗАЛИТА, щелей три, каждая не тоньше 1.7 единицы, и они
  /// отступают от краёв — иначе голова читается полосатой, а не
  /// зарешёченной.
  ///
  /// [stand] — подставка. У пары микрофонов её нет: они выглядывают из-за
  /// края плашки, и подставка осталась бы за кадром.
  /// [stemTo] — докуда тянуть стойку. Паре нужно вывести её ЗА край, а не
  /// оборвать на полпути.
  void _mic(Canvas canvas, {bool stand = true, double stemTo = 19.6}) {
    final fill = Paint()
      ..color = ink
      ..isAntiAlias = true;

    // Стойка рисуется ПЕРВОЙ и заходит под голову: иначе на стыке видна
    // ступенька в полпикселя.
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTRB(10.8, 12.0, 13.2, stemTo),
        const Radius.circular(0.9),
      ),
      fill,
    );
    if (stand) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          const Rect.fromLTRB(6.2, 19.6, 17.8, 22.2),
          const Radius.circular(1.3),
        ),
        fill,
      );
    }

    // Голова: верх круглый, низ скруглён меньше — так она «сидит» на
    // стойке, а не висит шариком.
    canvas.drawRRect(
      RRect.fromRectAndCorners(
        const Rect.fromLTRB(6.2, 1.6, 17.8, 15.4),
        topLeft: const Radius.circular(5.8),
        topRight: const Radius.circular(5.8),
        bottomLeft: const Radius.circular(4.2),
        bottomRight: const Radius.circular(4.2),
      ),
      fill,
    );
    final slat = Paint()
      ..color = paper
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.7
      ..strokeCap = StrokeCap.round
      ..isAntiAlias = true;
    for (final y in const [5.4, 8.6, 11.8]) {
      canvas.drawLine(Offset(8.4, y), Offset(15.6, y), slat);
    }
  }

  /// Два микрофона, заглядывающих навстречу друг другу из-за краёв.
  ///
  /// Поворот идёт вокруг ГОЛОВЫ, а не вокруг середины сетки: крутя вокруг
  /// середины, головы уезжают вниз, и наклон читается как «микрофон
  /// падает», а не «повернулся к собеседнику».
  ///
  /// ЧЕТВЕРТЬ ГОЛОВЫ ОСТАЁТСЯ ЗА КАДРОМ — это и есть «выглядывают».
  /// Меньше — и обрез читается как криво поставленный значок; больше — и
  /// от микрофона остаётся полумесяц, в котором его уже не узнать.
  void _micDuo(Canvas canvas) {
    void one(double headX, double rotation) {
      canvas.save();
      canvas.translate(headX, 12.0);
      canvas.rotate(rotation);
      canvas.scale(0.85);
      // 8.5 — середина ГОЛОВЫ по высоте, а не середина сетки.
      canvas.translate(-12, -8.5);
      // Стойка уходит далеко за сетку: её обрежет край плашки, и это
      // единственный способ показать, что микрофон стоит ЗА кадром.
      _mic(canvas, stand: false, stemTo: 30);
      canvas.restore();
    }

    one(3.2, 0.38);
    one(20.8, -0.38);
  }

  /// Окно сообщения: пузырь с хвостиком и две строки текста.
  ///
  /// Пузырь и хвостик склеиваются в ОДИН контур ([Path.combine]): нарисуй
  /// их по отдельности — и на стыке останется линия поперёк хвостика.
  void _message(Canvas canvas) {
    final bubble = Path()
      ..addRRect(RRect.fromRectAndRadius(
        const Rect.fromLTRB(2.6, 3.4, 21.4, 16.6),
        const Radius.circular(3.4),
      ));
    final tail = Path()
      ..moveTo(6.6, 14.0)
      ..lineTo(6.6, 21.0)
      ..lineTo(12.6, 15.2)
      ..close();
    final shape = Path.combine(PathOperation.union, bubble, tail);
    canvas.drawPath(shape, _fill);
    canvas.drawPath(shape, _line(1.8));
    canvas.drawLine(const Offset(6.6, 8.2), const Offset(17.4, 8.2), _line(1.7));
    canvas.drawLine(const Offset(6.6, 11.9), const Offset(14.2, 11.9), _line(1.7));
  }

  @override
  bool shouldRepaint(_ModeGlyphPainter old) =>
      old.kind != kind || old.ink != ink || old.paper != paper;
}
