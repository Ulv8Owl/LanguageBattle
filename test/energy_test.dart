import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:language_battle/core/game_access.dart';

/// Энергия живёт в трёх местах сразу: схема задаёт запас, воркер списывает
/// за вызовы, клиент показывает остаток. Разойтись им нельзя, а поймать
/// расхождение на экране невозможно: «0/10» вместо «0/50» выглядит просто
/// как пустой запас.
///
/// Поэтому проверки читают САМИ файлы схемы и воркера, а не копию чисел:
/// копия однажды отстанет, и тест этого не заметит.
void main() {
  String migration() =>
      File('supabase/migrations/0032_energy_per_call.sql').readAsStringSync();

  String worker() =>
      File('supabase/functions/evaluate-recording/index.ts').readAsStringSync();

  test('запас 50 и в схеме, и у клиента', () {
    final sql = migration();
    expect(sql, contains('alter column energy_max set default 50'));
    expect(sql, contains('alter column energy_current set default 50'));
    // Клиент рисует шкалу до ответа сервера по своей заглушке. Если она
    // отстанет от схемы, игрок увидит чужой потолок и решит, что запаса
    // меньше, чем есть.
    expect(WalletState.empty.energyMax, 50);
    expect(WalletState.fromJson(const {}).energyMax, 50);
  });

  test('вход в режим больше не списывает энергию', () {
    // Именно эта строка и была старой моделью «плата за заход». Вернуть её
    // означало бы брать дважды: и за вход, и за вызовы.
    expect(
      migration().contains('energy_current = energy_current - 1'),
      isFalse,
      reason: 'start_training_session не должна списывать за вход',
    );
    // А проверка остатка обязана остаться: с нулём в режим не пускают,
    // иначе списание после ответа уже ничего не ограничивает.
    expect(migration(), contains("raise exception 'no_energy'"));
  });

  test('цена вызова: один разбор — три энергии', () {
    // Прежняя связка стоила 1 (распознавание) + 2 (разбор). Один вызов
    // делает работу обоих, и цена та же: менять экономику игры заодно с
    // пайплайном — отдельное решение, которого никто не принимал.
    expect(worker(), contains('ENERGY_COST_OMNI") ?? 3'));
    // Прежних цен в коде остаться не должно: за что платят, видно по
    // одному месту.
    expect(worker().contains('ENERGY_COST_ASR'), isFalse);
    expect(worker().contains('ENERGY_COST_LLM'), isFalse);
  });


  test('за молчание провайдера и за кэш не платят', () {
    final ts = worker();
    // Платим только за ответ. Отказ провайдера бесплатен: игрок за нашу
    // неудачу платить не должен.
    expect(ts, contains('if (!omni.degraded) {'));
    // Кэша транскрипта больше нет — распознавание удалено, хранить нечего.
    expect(ts.contains('cached'), isFalse);
  });

  test('проверка уровня остаётся бесплатной', () {
    // Признак проверки должен доезжать до воркера: без него он не отличит
    // экзамен от игры и возьмёт плату там, где брать нельзя.
    expect(migration(), contains('is_placement boolean not null default false'));
    expect(migration(), contains('reference_elo, is_placement'));
    expect(worker(), contains('training_sessions(is_placement)'));
  });
}
