import 'dart:typed_data';

/// Dirección MAC unicast de 48 bits, validada y normalizada.
///
/// Acepta los formatos habituales: `AA:BB:CC:DD:EE:FF`, `AA-BB-CC-DD-EE-FF`,
/// `AABB.CCDD.EEFF` y `AABBCCDDEEFF`. Una MAC no es una credencial: solo
/// identifica la tarjeta de red a la que va dirigido el paquete mágico.
final class MacAddress {
  MacAddress._(this._bytes);

  static const int byteLength = 6;

  static final RegExp _hexPair = RegExp(r'^[0-9A-Fa-f]{2}$');
  static final RegExp _hexQuad = RegExp(r'^[0-9A-Fa-f]{4}$');
  static final RegExp _hexTwelve = RegExp(r'^[0-9A-Fa-f]{12}$');

  final Uint8List _bytes;

  /// Copia de los 6 bytes de la dirección.
  Uint8List get bytes => Uint8List.fromList(_bytes);

  /// Interpreta [input] o lanza [FormatException] con un mensaje para el usuario.
  static MacAddress parse(String input) {
    final hex = _extractHex(input.trim());
    final bytes = Uint8List(byteLength);
    for (var i = 0; i < byteLength; i++) {
      bytes[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
    }
    _ensureUnicastDevice(bytes, input);
    return MacAddress._(bytes);
  }

  static MacAddress? tryParse(String input) {
    try {
      return parse(input);
    } on FormatException {
      return null;
    }
  }

  /// Devuelve el mensaje de error de validación, o `null` si [input] es válida.
  static String? validate(String? input) {
    try {
      parse(input ?? '');
      return null;
    } on FormatException catch (error) {
      return error.message;
    }
  }

  static String _extractHex(String value) {
    if (value.isEmpty) {
      throw FormatException('Ingresa la dirección MAC.', value);
    }
    const invalidFormat = 'Formato de MAC no válido. Usa AA:BB:CC:DD:EE:FF.';
    final hasColon = value.contains(':');
    final hasDash = value.contains('-');
    final hasDot = value.contains('.');
    final separatorCount = [hasColon, hasDash, hasDot].where((s) => s).length;
    if (separatorCount > 1) {
      throw FormatException(invalidFormat, value);
    }
    if (hasColon || hasDash) {
      final groups = value.split(hasColon ? ':' : '-');
      if (groups.length != byteLength || !groups.every(_hexPair.hasMatch)) {
        throw FormatException(invalidFormat, value);
      }
      return groups.join();
    }
    if (hasDot) {
      final groups = value.split('.');
      if (groups.length != 3 || !groups.every(_hexQuad.hasMatch)) {
        throw FormatException(invalidFormat, value);
      }
      return groups.join();
    }
    if (!_hexTwelve.hasMatch(value)) {
      throw FormatException(invalidFormat, value);
    }
    return value;
  }

  static void _ensureUnicastDevice(Uint8List bytes, String input) {
    if (bytes.every((b) => b == 0x00)) {
      throw FormatException(
        'La MAC 00:00:00:00:00:00 no identifica a ningún equipo.',
        input,
      );
    }
    if (bytes.every((b) => b == 0xFF)) {
      throw FormatException(
        'La MAC de difusión FF:FF:FF:FF:FF:FF no identifica a un equipo.',
        input,
      );
    }
    // Bit I/G del primer octeto: 1 indica una dirección de grupo (multicast).
    if (bytes[0] & 0x01 == 0x01) {
      throw FormatException(
        'Es una MAC de multidifusión; una tarjeta de red usa una MAC unicast.',
        input,
      );
    }
  }

  @override
  String toString() => _bytes
      .map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase())
      .join(':');

  @override
  bool operator ==(Object other) =>
      other is MacAddress && other.toString() == toString();

  @override
  int get hashCode => toString().hashCode;
}
