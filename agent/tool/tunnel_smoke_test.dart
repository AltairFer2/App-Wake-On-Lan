import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:altair_agent_protocol/altair_agent_protocol.dart';
import 'package:altair_wake_agent/altair_wake_agent.dart';

/// Prueba de humo del túnel de escritorio remoto: abre el túnel y envía la
/// negociación inicial de RDP (X.224 Connection Request). Si el PC contesta
/// con un Connection Confirm, el agente llegó al Escritorio remoto. No
/// inicia sesión ni muestra la clave.
///
/// - Sin `--key-file`: levanta un agente temporal en este proceso, con una
///   clave nueva, contra el RDP real del PC (no requiere administrador).
/// - Con `--key-file` (y opcionalmente `--host` y `--port`): prueba el
///   agente instalado; leer su clave requiere administrador.
///
/// `dart run tool/tunnel_smoke_test.dart [--key-file ruta] [--host ip] [--port n]`
Future<void> main(List<String> arguments) async {
  final options = <String, String>{
    for (var i = 0; i + 1 < arguments.length; i += 2)
      arguments[i].replaceFirst('--', ''): arguments[i + 1],
  };
  final keyFile = options['key-file'];
  AgentServer? localAgent;
  final AgentKey key;
  final InternetAddress host;
  final int port;
  if (keyFile == null) {
    key = AgentKey.generate();
    localAgent = AgentServer(
      handler: RequestHandler(key: key, actions: _NoPowerActions()),
      logger: AgentLogger(null),
      port: 0,
    );
    await localAgent.start();
    host = InternetAddress.loopbackIPv4;
    port = localAgent.boundPort;
  } else {
    key = AgentKey.parse(File(keyFile).readAsStringSync());
    host = InternetAddress(options['host'] ?? '127.0.0.1');
    port = int.parse(options['port'] ?? '$defaultAgentPort');
  }
  try {
    exitCode = await _probe(key, host, port);
  } finally {
    await localAgent?.close();
  }
}

Future<int> _probe(AgentKey key, InternetAddress host, int port) async {
  final socket = await Socket.connect(host, port, timeout: const Duration(seconds: 5));
  final request = AgentRequest.create(AgentCommand.remoteDesktop, DateTime.now());
  socket.write('${request.encode(key)}\n');
  await socket.flush();
  final first = await readFirstLine(socket, timeout: const Duration(seconds: 5));
  if (first.line == null) {
    stdout.writeln('FALLO: el agente no respondió (clave distinta o agente antiguo).');
    socket.destroy();
    return 1;
  }
  final response = AgentResponse.decodeAndVerify(first.line!, key, expectedNonce: request.nonce);
  stdout.writeln('Respuesta firmada: ok=${response.ok} result=${response.result} error=${response.error?.wireName}');
  if (!response.ok) {
    socket.destroy();
    return 1;
  }

  final keys = TunnelKeys.derive(key, request.nonce);
  final outgoing = StreamController<List<int>>();
  unawaited(socket.addStream(encodeTunnelFrames(outgoing.stream, keys.appToAgent)));
  final incoming = StreamIterator(decodeTunnelFrames(first.rest, keys.agentToApp));

  // TPKT + X.224 Connection Request con RDP_NEG_REQ (TLS | CredSSP).
  outgoing.add(Uint8List.fromList([
    0x03, 0x00, 0x00, 0x13, // TPKT, 19 bytes
    0x0E, 0xE0, 0x00, 0x00, 0x00, 0x00, 0x00, // X.224 CR
    0x01, 0x00, 0x08, 0x00, 0x03, 0x00, 0x00, 0x00, // RDP_NEG_REQ
  ]));
  final hasReply = await incoming.moveNext().timeout(const Duration(seconds: 5));
  final reply = hasReply ? incoming.current : const <int>[];
  // TPKT (0x03) y código X.224 Connection Confirm (0xD0) en el byte 5.
  final confirmed = reply.length > 5 && reply[0] == 0x03 && reply[5] == 0xD0;
  stdout.writeln(confirmed
      ? 'OK: el Escritorio remoto respondió por el túnel (${reply.length} bytes, X.224 Connection Confirm).'
      : 'FALLO: respuesta inesperada de ${reply.length} bytes.');
  await outgoing.close();
  socket.destroy();
  return confirmed ? 0 : 1;
}

/// El agente temporal no ejecuta órdenes de energía.
class _NoPowerActions implements PowerActions {
  @override
  Future<void> scheduleShutdown() async => throw const PowerActionException('desactivado');

  @override
  Future<void> cancelShutdown() async => throw const PowerActionException('desactivado');

  @override
  Future<void> suspend() async => throw const PowerActionException('desactivado');

  @override
  Future<void> keepDisplayOn() async => throw const PowerActionException('desactivado');
}
