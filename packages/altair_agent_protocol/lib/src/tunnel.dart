import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'agent_key.dart';
import 'messages.dart';

// Túnel hacia el Escritorio remoto a través del agente.
//
// 1. La app envía una petición firmada [AgentCommand.remoteDesktop].
// 2. El agente conecta con RDP en el propio PC y responde firmado con
//    [tunnelResult] (o con un error si no pudo).
// 3. Por la misma conexión viajan tramas en ambos sentidos:
//    `longitud (4 bytes, big-endian) | datos | HMAC-SHA256 (32 bytes)`.
//    El HMAC cubre un contador de tramas y los datos, con una clave por
//    sentido derivada de la clave del agente y del nonce de la petición.
//
// Las tramas no cifran: el contenido ya va cifrado por el TLS de RDP, cuyo
// certificado verifica la app. El HMAC impide que alguien en la ruta
// inyecte, reordene o secuestre la conexión ya autenticada.

/// Resultado del agente cuando el túnel quedó abierto.
const String tunnelResult = 'tunnel';

/// Datos máximos por trama.
const int maxTunnelPayload = 16 * 1024;

const int _lengthBytes = 4;
const int _macBytes = 32;

/// Claves de un túnel, una por sentido.
class TunnelKeys {
  const TunnelKeys({required this.appToAgent, required this.agentToApp});

  /// Deriva las claves de la sesión que abrió la petición con [requestNonce].
  factory TunnelKeys.derive(AgentKey key, String requestNonce) => TunnelKeys(
    appToAgent: key.derive('altair-wake/$protocolVersion/tunnel|app-to-agent|$requestNonce'),
    agentToApp: key.derive('altair-wake/$protocolVersion/tunnel|agent-to-app|$requestNonce'),
  );

  final Uint8List appToAgent;
  final Uint8List agentToApp;

  @override
  String toString() => 'TunnelKeys(***)';
}

/// Trama alterada, desordenada o mal formada: la conexión debe cerrarse.
class TunnelIntegrityException implements Exception {
  const TunnelIntegrityException(this.message);

  final String message;

  @override
  String toString() => 'TunnelIntegrityException: $message';
}

/// Empaqueta [input] en tramas autenticadas con [key].
Stream<List<int>> encodeTunnelFrames(Stream<List<int>> input, Uint8List key) async* {
  final hmac = Hmac(sha256, key);
  var sequence = 0;
  await for (final chunk in input) {
    for (var start = 0; start < chunk.length; start += maxTunnelPayload) {
      final end = math.min(start + maxTunnelPayload, chunk.length);
      final length = end - start;
      final frame = Uint8List(_lengthBytes + length + _macBytes);
      ByteData.sublistView(frame).setUint32(0, length);
      frame.setRange(_lengthBytes, _lengthBytes + length, chunk, start);
      final payload = Uint8List.sublistView(frame, _lengthBytes, _lengthBytes + length);
      frame.setRange(_lengthBytes + length, frame.length, _mac(hmac, sequence++, payload));
      yield frame;
    }
  }
}

/// Verifica y desempaqueta las tramas de [input]. Termina con
/// [TunnelIntegrityException] ante la primera trama inválida.
Stream<List<int>> decodeTunnelFrames(Stream<List<int>> input, Uint8List key) async* {
  final hmac = Hmac(sha256, key);
  var sequence = 0;
  var pending = Uint8List(0);
  await for (final chunk in input) {
    pending = pending.isEmpty
        ? Uint8List.fromList(chunk)
        : (BytesBuilder(copy: false)
                ..add(pending)
                ..add(chunk))
              .takeBytes();
    var offset = 0;
    while (pending.length - offset >= _lengthBytes) {
      final length = ByteData.sublistView(pending, offset).getUint32(0);
      if (length == 0 || length > maxTunnelPayload) {
        throw const TunnelIntegrityException('Trama de tamaño inválido.');
      }
      final payloadStart = offset + _lengthBytes;
      final frameEnd = payloadStart + length + _macBytes;
      if (pending.length < frameEnd) break;
      final payload = Uint8List.sublistView(pending, payloadStart, payloadStart + length);
      final mac = Uint8List.sublistView(pending, payloadStart + length, frameEnd);
      if (!_equalInConstantTime(_mac(hmac, sequence++, payload), mac)) {
        throw const TunnelIntegrityException('Trama no auténtica.');
      }
      yield payload;
      offset = frameEnd;
    }
    if (offset > 0) pending = Uint8List.sublistView(pending, offset);
  }
  if (pending.isNotEmpty) {
    throw const TunnelIntegrityException('La conexión terminó a mitad de una trama.');
  }
}

List<int> _mac(Hmac hmac, int sequence, Uint8List payload) {
  final sink = _DigestSink();
  final input = hmac.startChunkedConversion(sink);
  input
    ..add((ByteData(8)..setUint64(0, sequence)).buffer.asUint8List())
    ..add(payload)
    ..close();
  return sink.digest.bytes;
}

bool _equalInConstantTime(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}

class _DigestSink implements Sink<Digest> {
  late Digest digest;

  @override
  void add(Digest data) => digest = data;

  @override
  void close() {}
}

/// Primera línea de una conexión y el resto de sus datos.
class FirstLine {
  const FirstLine(this.line, this.rest);

  /// `null` si la conexión terminó, tardó o superó el tamaño antes del
  /// salto de línea.
  final String? line;

  /// Lo que llega después de la línea (para el túnel). Si no se escucha, la
  /// lectura queda en pausa hasta que se cierre el socket.
  final Stream<List<int>> rest;
}

/// Lee la primera línea (petición o respuesta del protocolo) sin perder los
/// datos que la siguen en el mismo paquete.
Future<FirstLine> readFirstLine(
  Stream<List<int>> input, {
  required Duration timeout,
  int maxBytes = maxMessageBytes,
}) async {
  final buffer = BytesBuilder(copy: false);
  final line = Completer<String?>();
  final rest = StreamController<List<int>>();
  late final StreamSubscription<List<int>> subscription;

  void finishLine(String? value) {
    if (!line.isCompleted) line.complete(value);
  }

  subscription = input.listen(
    (chunk) {
      if (line.isCompleted) {
        rest.add(chunk);
        return;
      }
      final newline = chunk.indexOf(10);
      buffer.add(newline == -1 ? chunk : chunk.sublist(0, newline));
      if (buffer.length > maxBytes) {
        finishLine(null);
      } else if (newline != -1) {
        finishLine(utf8.decode(buffer.takeBytes(), allowMalformed: true));
        if (newline + 1 < chunk.length) rest.add(chunk.sublist(newline + 1));
      }
    },
    onError: (Object error, StackTrace stack) {
      if (line.isCompleted) {
        rest.addError(error, stack);
      } else {
        finishLine(null);
      }
    },
    onDone: () {
      finishLine(null);
      unawaited(rest.close());
    },
  );
  rest
    ..onPause = subscription.pause
    ..onResume = subscription.resume
    ..onCancel = subscription.cancel;

  final value = await line.future.timeout(timeout, onTimeout: () => null);
  if (value == null) await subscription.cancel();
  return FirstLine(value, rest.stream);
}
