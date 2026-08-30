import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:language_battle/widgets/voice_message_bubble.dart';

// Supabase здесь не инициализируется намеренно: пузырь обращается к нему
// только по нажатию на воспроизведение, а рендер должен работать и без
// сети — иначе лента боя/соло падала бы на первом же голосовом.
void main() {
  Widget host(Widget child) => MaterialApp(
        home: Scaffold(body: ListView(children: [child])),
      );

  testWidgets('пузырь голосового рисуется: аватар, кнопка, дорожка', (tester) async {
    await tester.pumpWidget(host(const VoiceMessageBubble(
      audioStoragePath: 'training/s/r/u_1.wav',
      name: 'Арсений',
      alignRight: true,
    )));

    expect(find.byType(VoiceMessageBubble), findsOneWidget);
    expect(find.byIcon(Icons.play_arrow), findsOneWidget);
    final size = tester.getSize(find.byType(VoiceMessageBubble));
    expect(size.height, greaterThan(20), reason: 'пузырь не должен схлопываться в ноль');
  });

  testWidgets('балл показывается, когда он уже есть', (tester) async {
    await tester.pumpWidget(host(const VoiceMessageBubble(
      audioStoragePath: 'training/s/r/u_2.wav',
      name: 'Арсений',
      alignRight: true,
      score: 7,
    )));
    expect(find.text('7'), findsOneWidget);
  });

  testWidgets('без балла пузырь ничего не показывает на его месте', (tester) async {
    // В бою балл и разбор приходят отдельным сообщением ниже. Индикатор на
    // самом пузыре читался как «голосовое ещё грузится», хотя грузилась
    // оценка, — поэтому здесь его быть не должно.
    await tester.pumpWidget(host(const VoiceMessageBubble(
      audioStoragePath: 'training/s/r/u_1.wav',
      name: 'Арсений',
      alignRight: false,
    )));
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });
}
