import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:altair_agent_protocol/altair_agent_protocol.dart';
import 'package:altair_wake/features/remote_desktop/data/rdp_tunnel.dart';
import 'package:flutter_test/flutter_test.dart';

/// Agente mínimo con el mismo protocolo: abre el túnel y hace de RDP
/// devolviendo en mayúsculas lo que recibe.
class FakeTunnelAgent {
  FakeTunnelAgent(this.key, {this.reply = AgentReply.tunnel});

  final AgentKey key;
  final AgentReply reply;
  late final ServerSocket _server;

  int get port => _server.port;

  Future<void> start() async {
    _server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen(_handle);
  }

  Future<void> close() => _server.close();

  Future<void> _handle(Socket socket) async {
    final first = await readFirstLine(socket, timeout: const Duration(seconds: 2));
    final AgentRequest request;
    try {
      request = AgentRequest.decodeAndVerify(
        first.line ?? '',
        key,
        now: DateTime.now(),
        replayGuard: ReplayGuard(),
      );
    } on AgentProtocolException {
      socket.destroy();
      return;
    }
    final ok = reply == AgentReply.tunnel;
    socket.write(
      '${AgentResponse(
        requestNonce: request.nonce,
        ok: ok,
        agentTime: DateTime.now(),
        result: ok ? tunnelResult : null,
        error: ok ? null : AgentErrorCode.failed,
      ).encode(key)}\n',
    );
    await socket.flush();
    if (!ok) {
      socket.destroy();
      return;
    }
    final keys = TunnelKeys.derive(key, request.nonce);
    final uppercased = decodeTunnelFrames(first.rest, keys.appToAgent)
        .map((chunk) => utf8.encode(utf8.decode(chunk).toUpperCase()));
    await socket.addStream(encodeTunnelFrames(uppercased, keys.agentToApp));
    socket.destroy();
  }
}

enum AgentReply { tunnel, failed }

void main() {
  final key = AgentKey.generate();

  test('el puerto local es estable por equipo y está en su rango', () {
    final port = tunnelLocalPortFor('pc-1');
    expect(tunnelLocalPortFor('pc-1'), port);
    expect(port, inInclusiveRange(40000, 49999));
    expect(tunnelLocalPortFor('pc-2'), isNot(port));
  });

  group('RdpTunnel (isolate, loopback)', () {
    late FakeTunnelAgent agent;

    tearDown(() => agent.close());

    test('FreeRDP habla con RDP a través del puerto local', () async {
      agent = FakeTunnelAgent(key);
      await agent.start();
      final tunnel = await RdpTunnel.open(
        agent: InternetAddress.loopbackIPv4,
        agentPort: agent.port,
        key: key,
      );
      final freeRdp = await Socket.connect(InternetAddress.loopbackIPv4, tunnel.localPort);
      final replies = StreamIterator(utf8.decoder.bind(freeRdp));
      freeRdp.write('hola');
      await freeRdp.flush();
      expect(await replies.moveNext(), isTrue);
      expect(replies.current, 'HOLA');

      // Solo se acepta la primera conexión: el puerto ya no escucha.
      await expectLater(
        Socket.connect(InternetAddress.loopbackIPv4, tunnel.localPort),
        throwsA(isA<SocketException>()),
      );

      freeRdp.destroy();
      await tunnel.done.timeout(const Duration(seconds: 5));
    });

    test('cerrar antes de que FreeRDP conecte termina el isolate', () async {
      agent = FakeTunnelAgent(key);
      await agent.start();
      final tunnel = await RdpTunnel.open(
        agent: InternetAddress.loopbackIPv4,
        agentPort: agent.port,
        key: key,
      );
      await tunnel.close();
      await expectLater(
        Socket.connect(InternetAddress.loopbackIPv4, tunnel.localPort),
        throwsA(isA<SocketException>()),
      );
    });

    test('con otra clave el agente no responde: unauthorized', () async {
      agent = FakeTunnelAgent(AgentKey.generate());
      await agent.start();
      await expectLater(
        RdpTunnel.open(agent: InternetAddress.loopbackIPv4, agentPort: agent.port, key: key),
        throwsA(
          isA<RdpTunnelException>().having(
            (error) => error.failure,
            'failure',
            RdpTunnelFailure.unauthorized,
          ),
        ),
      );
    });

    test('si el PC no puede abrir RDP se informa el motivo', () async {
      agent = FakeTunnelAgent(key, reply: AgentReply.failed);
      await agent.start();
      await expectLater(
        RdpTunnel.open(agent: InternetAddress.loopbackIPv4, agentPort: agent.port, key: key),
        throwsA(
          isA<RdpTunnelException>()
              .having((error) => error.failure, 'failure', RdpTunnelFailure.rejected)
              .having((error) => error.message, 'message', contains('escritorio remoto')),
        ),
      );
    });

    test('sin agente escuchando: unreachable', () async {
      agent = FakeTunnelAgent(key);
      await agent.start();
      final port = agent.port;
      await agent.close();
      await expectLater(
        RdpTunnel.open(agent: InternetAddress.loopbackIPv4, agentPort: port, key: key),
        throwsA(
          isA<RdpTunnelException>().having(
            (error) => error.failure,
            'failure',
            RdpTunnelFailure.unreachable,
          ),
        ),
      );
    });
  });
}
