import 'package:altair_wake/features/remote_desktop/domain/text_diff.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  void expectDiff(String before, String after, int deleted, String inserted) {
    final diff = TextDiff.between(before, after);
    expect((diff.deleted, diff.inserted), (deleted, inserted), reason: '"$before" → "$after"');
  }

  test('escribir agrega al final', () => expectDiff('hol', 'hola', 0, 'a'));

  test('borrar envía retrocesos', () => expectDiff('hola', 'ho', 2, ''));

  test('una palabra deslizada llega entera', () => expectDiff('', 'mañana ', 0, 'mañana '));

  test('una sugerencia sustituye la palabra en composición', () {
    expectDiff('dile qe', 'dile que ', 1, 'ue ');
    expectDiff('teh', 'the ', 2, 'he ');
  });

  test('sin cambios no envía nada', () => expectDiff('abc', 'abc', 0, ''));

  test('un emoji cuenta como un solo retroceso y no se parte', () {
    expectDiff('ok 👍', 'ok ', 1, '');
    expectDiff('ok 👍', 'ok 👎', 1, '👎');
  });
}
