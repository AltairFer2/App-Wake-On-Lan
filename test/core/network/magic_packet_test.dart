import 'package:altair_wake/core/network/mac_address.dart';
import 'package:altair_wake/core/network/magic_packet.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final mac = MacAddress.parse('D8:BB:C1:0A:FF:01');
  const macBytes = [0xD8, 0xBB, 0xC1, 0x0A, 0xFF, 0x01];

  test('mide 102 bytes', () {
    expect(MagicPacket.length, 102);
    expect(MagicPacket.build(mac), hasLength(102));
  });

  test('empieza con 6 bytes 0xFF', () {
    expect(MagicPacket.build(mac).sublist(0, 6), List.filled(6, 0xFF));
  });

  test('contiene 16 repeticiones consecutivas de la MAC', () {
    final packet = MagicPacket.build(mac);
    for (var i = 0; i < 16; i++) {
      final start = 6 + i * 6;
      expect(packet.sublist(start, start + 6), macBytes, reason: 'repetición $i');
    }
  });

  test('coincide con el paquete de referencia byte a byte', () {
    final expected = [
      ...List.filled(6, 0xFF),
      for (var i = 0; i < 16; i++) ...macBytes,
    ];
    expect(MagicPacket.build(mac), expected);
  });
}
