import 'dart:typed_data';

import 'mac_address.dart';

/// Construye el paquete mágico de Wake-on-LAN (formato AMD Magic Packet).
///
/// Estructura: 6 bytes `0xFF` de sincronización seguidos de 16 repeticiones
/// consecutivas de la MAC de destino. Longitud total: 102 bytes. El formato no
/// depende del transporte: el mismo payload sirve sobre UDP/IPv4 o UDP/IPv6.
abstract final class MagicPacket {
  static const int syncByte = 0xFF;
  static const int syncLength = 6;
  static const int macRepetitions = 16;
  static const int length =
      syncLength + macRepetitions * MacAddress.byteLength;

  static Uint8List build(MacAddress mac) {
    final packet = Uint8List(length);
    packet.fillRange(0, syncLength, syncByte);
    final macBytes = mac.bytes;
    for (var i = 0; i < macRepetitions; i++) {
      packet.setAll(syncLength + i * MacAddress.byteLength, macBytes);
    }
    return packet;
  }
}
