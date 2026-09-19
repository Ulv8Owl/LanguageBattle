import 'dart:math' as math;

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

  /// Микрофон — «Голос».
  mic,

  /// Два микрофона навстречу друг другу — «Голос Vs Голос».
  micDuo,

  /// Окно сообщения со строками текста — «Общение».
  message,
}

class ModeGlyph extends StatelessWidget {
  final ModeGlyphKind kind;
  final double size;
  final Color ink;
  final Color paper;

  const ModeGlyph(
    this.kind, {
    super.key,
    this.size = 19,
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
        _mic(canvas, stroke: 1.9);
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
  /// Точка схода НИЖЕ значка (y = 21), а не в его середине: веер, сведённый
  /// по центру, читается как звезда, а не как карты.
  void _cards(Canvas canvas) {
    const pivot = Offset(12, 20.6);
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

  /// Микрофон: капсула, дуга-держатель, ножка и подставка.
  void _mic(Canvas canvas, {required double stroke}) {
    final body = RRect.fromRectAndRadius(
      const Rect.fromLTRB(9.2, 2.4, 14.8, 13.4),
      const Radius.circular(2.8),
    );
    canvas.drawRRect(body, Paint()..color = ink..isAntiAlias = true);
    // Дуга — нижняя половина окружности вокруг капсулы.
    canvas.drawArc(
      const Rect.fromLTRB(6.0, 5.0, 18.0, 17.0),
      0,
      math.pi,
      false,
      _line(stroke),
    );
    canvas.drawLine(const Offset(12, 17.0), const Offset(12, 20.4), _line(stroke));
    canvas.drawLine(const Offset(8.4, 20.8), const Offset(15.6, 20.8), _line(stroke));
  }

  /// Два микрофона, наклонённых навстречу, — режим «голос против голоса».
  ///
  /// Каждый рисуется тем же [_mic], но сжатым: толщина линий задана с
  /// запасом, иначе после сжатия дуга и ножка становятся тоньше волоса.
  void _micDuo(Canvas canvas) {
    void one(double dx, double rotation) {
      canvas.save();
      canvas.translate(dx, 12.4);
      canvas.rotate(rotation);
      canvas.scale(0.70);
      canvas.translate(-12, -12);
      _mic(canvas, stroke: 2.5);
      canvas.restore();
    }

    one(6.9, -0.20);
    one(17.1, 0.20);
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
