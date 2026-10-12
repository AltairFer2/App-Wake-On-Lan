import 'dart:convert';
import 'dart:math';

import 'agent_key.dart';
import 'replay_guard.dart';

const int protocolVersion = 1;

/// Puerto TCP que usa el instalador del agente por defecto.
const int defaultAgentPort = 47123;

/// Tamaño máximo de una línea del protocolo, en bytes.
const int maxMessageBytes = 4096;

/// Desfase máximo de reloj aceptado entre teléfono y PC.
const Duration maxClockSkew = Duration(seconds: 30);

enum AgentCommand {
  status('status'),
  suspend('suspend'),
  shutdown('shutdown'),
  cancelShutdown('cancel');

  const AgentCommand(this.wireName);

  final String wireName;

  static AgentCommand? fromWire(String value) {
    for (final command in values) {
      if (command.wireName == value) return command;
    }
    return null;
  }
}

enum AgentErrorCode {
  badRequest('bad_request'),
  unauthorized('unauthorized'),
  clockSkew('clock_skew'),
  replay('replay'),
  failed('failed');

  const AgentErrorCode(this.wireName);

  final String wireName;

  static AgentErrorCode? fromWire(String? value) {
    for (final code in values) {
      if (code.wireName == value) return code;
    }
    return null;
  }
}

/// Mensaje que no supera la validación del protocolo.
class AgentProtocolException implements Exception {
  const AgentProtocolException(this.code, this.message);

  final AgentErrorCode code;
  final String message;

  @override
  String toString() => 'AgentProtocolException(${code.wireName}): $message';
}

class AgentRequest {
  const AgentRequest({
    required this.command,
    required this.timestamp,
    required this.nonce,
  });

  factory AgentRequest.create(AgentCommand command, DateTime now) =>
      AgentRequest(command: command, timestamp: now, nonce: generateNonce());

  final AgentCommand command;
  final DateTime timestamp;

  /// 128 bits aleatorios en hexadecimal.
  final String nonce;

  String get _canonical =>
      'altair-wake/$protocolVersion/req|${command.wireName}|'
      '${timestamp.millisecondsSinceEpoch}|$nonce';

  String encode(AgentKey key) => jsonEncode({
    'v': protocolVersion,
    'cmd': command.wireName,
    'ts': timestamp.millisecondsSinceEpoch,
    'nonce': nonce,
    'sig': key.sign(_canonical),
  });

  /// Decodifica y valida firma, vigencia y unicidad. Lanza
  /// [AgentProtocolException] si la petición no debe ejecutarse.
  static AgentRequest decodeAndVerify(
    String line,
    AgentKey key, {
    required DateTime now,
    required ReplayGuard replayGuard,
  }) {
    final json = _decodeObject(line);
    final command = AgentCommand.fromWire(_field<String>(json, 'cmd'));
    final timestamp = _field<int>(json, 'ts');
    final nonce = _field<String>(json, 'nonce');
    final signature = _field<String>(json, 'sig');
    if (json['v'] != protocolVersion || command == null || !_isNonce(nonce)) {
      throw const AgentProtocolException(
        AgentErrorCode.badRequest,
        'Petición mal formada.',
      );
    }
    final request = AgentRequest(
      command: command,
      timestamp: DateTime.fromMillisecondsSinceEpoch(timestamp),
      nonce: nonce,
    );
    // La firma se comprueba antes que el tiempo para no revelar el reloj del
    // agente a quien no tiene la clave.
    if (!key.verify(request._canonical, signature)) {
      throw const AgentProtocolException(
        AgentErrorCode.unauthorized,
        'Firma inválida.',
      );
    }
    if (now.difference(request.timestamp).abs() > maxClockSkew) {
      throw const AgentProtocolException(
        AgentErrorCode.clockSkew,
        'La marca de tiempo está fuera de la ventana permitida.',
      );
    }
    if (!replayGuard.accept(nonce, now)) {
      throw const AgentProtocolException(
        AgentErrorCode.replay,
        'Petición repetida.',
      );
    }
    return request;
  }
}

class AgentResponse {
  const AgentResponse({
    required this.requestNonce,
    required this.ok,
    required this.agentTime,
    this.result,
    this.error,
  });

  /// Nonce de la petición respondida: vincula la respuesta a esa petición.
  final String requestNonce;
  final bool ok;
  final DateTime agentTime;

  /// Texto breve del resultado, p. ej. `awake` o `accepted`.
  final String? result;
  final AgentErrorCode? error;

  String get _canonical =>
      'altair-wake/$protocolVersion/res|$requestNonce|$ok|${result ?? ''}|'
      '${error?.wireName ?? ''}|${agentTime.millisecondsSinceEpoch}';

  String encode(AgentKey key) => jsonEncode({
    'v': protocolVersion,
    'nonce': requestNonce,
    'ok': ok,
    'result': result,
    'error': error?.wireName,
    'ts': agentTime.millisecondsSinceEpoch,
    'sig': key.sign(_canonical),
  });

  /// Lanza [AgentProtocolException] con [AgentErrorCode.unauthorized] si la
  /// respuesta no está firmada con [key] o no corresponde a [expectedNonce].
  static AgentResponse decodeAndVerify(
    String line,
    AgentKey key, {
    required String expectedNonce,
  }) {
    final json = _decodeObject(line);
    final ok = json['ok'];
    final result = json['result'];
    final errorWire = json['error'];
    if (json['v'] != protocolVersion ||
        ok is! bool ||
        (result != null && result is! String) ||
        (errorWire != null && errorWire is! String)) {
      throw const AgentProtocolException(
        AgentErrorCode.badRequest,
        'Respuesta mal formada.',
      );
    }
    final response = AgentResponse(
      requestNonce: _field<String>(json, 'nonce'),
      ok: ok,
      agentTime: DateTime.fromMillisecondsSinceEpoch(_field<int>(json, 'ts')),
      result: result as String?,
      error: AgentErrorCode.fromWire(errorWire as String?),
    );
    if (!key.verify(response._canonical, _field<String>(json, 'sig')) ||
        response.requestNonce != expectedNonce) {
      throw const AgentProtocolException(
        AgentErrorCode.unauthorized,
        'Respuesta no auténtica.',
      );
    }
    return response;
  }
}

String generateNonce() {
  final random = Random.secure();
  return List.generate(
    16,
    (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
}

final RegExp _noncePattern = RegExp(r'^[0-9a-f]{32}$');

bool _isNonce(String value) => _noncePattern.hasMatch(value);

Map<String, Object?> _decodeObject(String line) {
  if (utf8.encode(line).length > maxMessageBytes) {
    throw const AgentProtocolException(
      AgentErrorCode.badRequest,
      'Mensaje demasiado grande.',
    );
  }
  try {
    final decoded = jsonDecode(line);
    if (decoded is Map<String, Object?>) return decoded;
  } on FormatException {
    // Se informa abajo como mensaje mal formado.
  }
  throw const AgentProtocolException(
    AgentErrorCode.badRequest,
    'El mensaje no es un objeto JSON.',
  );
}

T _field<T>(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! T) {
    throw AgentProtocolException(
      AgentErrorCode.badRequest,
      'Campo "$key" ausente o inválido.',
    );
  }
  return value;
}
