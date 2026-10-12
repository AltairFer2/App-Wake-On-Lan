import 'package:altair_wake/core/network/mac_address.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('MacAddress.parse', () {
    test('acepta los formatos habituales y normaliza a mayúsculas con ":"', () {
      const expected = 'D8:BB:C1:0A:FF:01';
      for (final input in [
        'd8:bb:c1:0a:ff:01',
        'D8-BB-C1-0A-FF-01',
        'd8bb.c10a.ff01',
        'D8BBC10AFF01',
        '  d8:bb:c1:0a:ff:01  ',
      ]) {
        expect(MacAddress.parse(input).toString(), expected, reason: input);
      }
    });

    test('expone los 6 bytes', () {
      expect(
        MacAddress.parse('00:23:45:67:89:AB').bytes,
        [0x00, 0x23, 0x45, 0x67, 0x89, 0xAB],
      );
    });

    test('rechaza formatos inválidos', () {
      for (final input in [
        '',
        'D8:BB:C1:0A:FF',
        'D8:BB:C1:0A:FF:01:02',
        'D8:BB:C1:0A:FF:0G',
        'D8:BB-C1:0A:FF:01',
        'D8BBC10AFF0',
        'D8BB.C10A.FF',
        'D8:B:C1:0A:FF:011',
      ]) {
        expect(
          () => MacAddress.parse(input),
          throwsFormatException,
          reason: input,
        );
      }
    });

    test('rechaza direcciones que no identifican a una tarjeta', () {
      expect(() => MacAddress.parse('00:00:00:00:00:00'), throwsFormatException);
      expect(() => MacAddress.parse('FF:FF:FF:FF:FF:FF'), throwsFormatException);
      // Bit I/G activo: dirección multicast.
      expect(() => MacAddress.parse('01:00:5E:00:00:01'), throwsFormatException);
    });
  });

  test('validate devuelve null si es válida y un mensaje si no', () {
    expect(MacAddress.validate('D8:BB:C1:0A:FF:01'), isNull);
    expect(MacAddress.validate(null), isNotNull);
    expect(MacAddress.validate('xyz'), contains('Formato'));
  });

  test('tryParse devuelve null en lugar de lanzar', () {
    expect(MacAddress.tryParse('nope'), isNull);
    expect(MacAddress.tryParse('D8BBC10AFF01'), isNotNull);
  });

  test('igualdad por valor', () {
    expect(MacAddress.parse('d8bbc10aff01'), MacAddress.parse('D8-BB-C1-0A-FF-01'));
  });
}
