import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// Clave compartida de 256 bits entre la aplicación y el agente.
///
/// Se transporta como base64url sin relleno (43 caracteres) para poder
/// copiarla o escribirla sin caracteres especiales.
final class AgentKey {
  AgentKey._(this._bytes);

  static const int length = 32;

  final Uint8List _bytes;

  factory AgentKey.generate() {
    final random = Random.secure();
    return AgentKey._(
      Uint8List.fromList(List.generate(length, (_) => random.nextInt(256))),
    );
  }

  /// Lanza [FormatException] si [encoded] no es una clave válida.
  factory AgentKey.parse(String encoded) {
    final value = encoded.trim();
    final Uint8List bytes;
    try {
      bytes = base64Url.decode(base64Url.normalize(value));
    } on FormatException {
      throw FormatException('La clave no es base64url válido.', value);
    }
    if (bytes.length != length) {
      throw FormatException('La clave debe tener $length bytes.', value);
    }
    return AgentKey._(bytes);
  }

  static AgentKey? tryParse(String encoded) {
    try {
      return AgentKey.parse(encoded);
    } on FormatException {
      return null;
    }
  }

  String encode() => base64Url.encode(_bytes).replaceAll('=', '');

  /// Firma [message] con HMAC-SHA256 y devuelve el resultado en hexadecimal.
  String sign(String message) =>
      Hmac(sha256, _bytes).convert(utf8.encode(message)).toString();

  /// Compara la firma en tiempo constante para no filtrar información por
  /// tiempos de respuesta.
  bool verify(String message, String signature) {
    final expected = sign(message);
    if (signature.length != expected.length) return false;
    var diff = 0;
    for (var i = 0; i < expected.length; i++) {
      diff |= expected.codeUnitAt(i) ^ signature.codeUnitAt(i);
    }
    return diff == 0;
  }

  /// Nunca expone el material de la clave en registros o excepciones.
  @override
  String toString() => 'AgentKey(***)';
}
