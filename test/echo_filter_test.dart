import 'package:flutter_test/flutter_test.dart';
import 'package:znaika/echo_filter.dart';
import 'package:znaika/transcriber.dart';

Utterance me(double start, double end, String text) => Utterance(start, end, meLabel, text);
Utterance others(double start, double end, String text) => Utterance(start, end, othersLabel, text);

List<String> lines(List<Utterance> list) => list.map((u) => u.line).toList();

void main() {
  test('эхо с другими окончаниями и пунктуацией убирается', () {
    // Реальный прогон: динамики MacBook, микрофон слышит собеседника.
    final result = dropEchoes([
      others(8.1, 12.1, 'Вторая реплика: «Релиз переносим на пятницу».'),
      me(8.2, 12.1, 'Вторая реплика: релиз переносим на Пятницы.'),
    ]);
    expect(result.map((u) => u.speaker), [othersLabel]);
  });

  test('искажённое эхо с потерянным началом убирается', () {
    final result = dropEchoes([
      others(2.9, 6.0, 'Гон номер два. Фраза через 2 секунды после старта.'),
      me(3.1, 6.1, 'Номер два сразу через 2 секунды после старта.'),
    ]);
    expect(result.map((u) => u.speaker), [othersLabel]);
  });

  test('эхо, разрезанное на фразы иначе, сравнивается с соседними репликами вместе', () {
    final result = dropEchoes([
      others(1.0, 3.0, 'Давайте обсудим релиз.'),
      others(3.6, 6.0, 'Его переносим на пятницу.'),
      me(1.1, 6.1, 'Давайте обсудим релиз, его переносим на пятницу.'),
    ]);
    expect(result.map((u) => u.speaker), [othersLabel, othersLabel]);
  });

  test('настоящий ответ «Я» остаётся', () {
    // Из тестовой встречи: реплики по очереди, без эха.
    final input = [
      me(0.9, 7.0, 'Всем привет. Давайте быстро пройдёмся по планам на спринт. Анна, начнёшь с платёжки?'),
      others(7.8, 16.0, 'Интеграцию с новым платёжным шлюзом мы почти закончили, осталось сделать обработку возвратов.'),
      me(16.8, 20.0, 'Хорошо, то есть к четвергу успеваем?'),
      others(20.8, 26.0, 'К четвергу успеем, если Игорь поднимет тестовый стенд до среды.'),
      me(26.8, 31.0, 'Понял. Я сам напишу Игорю сегодня и попрошу стенд до среды.'),
    ];
    expect(lines(dropEchoes(input)), lines(input));
  });

  test('совпадение по словам, но далеко по времени — не эхо', () {
    final input = [
      others(1.0, 3.0, 'Релиз переносим на пятницу.'),
      me(10.0, 12.0, 'Релиз переносим на пятницу.'),
    ];
    expect(lines(dropEchoes(input)), lines(input));
  });

  test('без собеседников ничего не убирается', () {
    final input = [me(0, 1, 'Проверка.')];
    expect(lines(dropEchoes(input)), lines(input));
  });
}
