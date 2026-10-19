import 'dart:convert';
import 'dart:io';

import 'package:altair_agent_protocol/altair_agent_protocol.dart';
import 'package:altair_wake/features/power_control/data/agent_client.dart';
import 'package:altair_wake/features/power_control/domain/power_control_service.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fakes.dart';

/// Agente mínimo sobre loopback que aplica el protocolo real.
class LoopbackAgent {
  LoopbackAgent(
    this.key, {
    this.respond = true,
    this.fail = false,
    this.address,
    this.bindPort = 0,
  });

  final AgentKey key;
  final bool respond;
  final bool fail;
  final InternetAddress? address;
  final int bindPort;
  final List<AgentCommand> received = [];
  late final ServerSocket _server;

  int get port => _server.port;

  Future<void> start() async {
    _server = await ServerSocket.bind(
      address ?? InternetAddress.loopbackIPv4,
      bindPort,
    );
    _server.listen((socket) async {
      final line = await utf8.decoder.bind(socket).transform(const LineSplitter()).first;
      try {
        final request = AgentRequest.decodeAndVerify(
          line,
          key,
          now: DateTime.now(),
          replayGuard: ReplayGuard(),
        );
        received.add(request.command);
        if (respond) {
          socket.write(
            '${AgentResponse(
              requestNonce: request.nonce,
              ok: !fail,
              agentTime: DateTime.now(),
              result: fail ? null : 'awake',
              error: fail ? AgentErrorCode.failed : null,
            ).encode(key)}\n',
          );
          await socket.flush();
        }
      } on AgentProtocolException {
        // Igual que el agente real: sin respuesta a peticiones no válidas.
      }
      socket.destroy();
    });
  }

  Future<void> close() => _server.close();
}

void main() {
  final key = AgentKey.generate();
  const client = AgentClient(timeout: Duration(seconds: 2));

  Future<LoopbackAgent> startAgent({
    bool respond = true,
    bool fail = false,
    InternetAddress? address,
    int port = 0,
  }) async {
    final agent = LoopbackAgent(
      key,
      respond: respond,
      fail: fail,
      address: address,
      bindPort: port,
    );
    await agent.start();
    addTearDown(agent.close);
    return agent;
  }

  test('orden aceptada con respuesta autenticada', () async {
    final agent = await startAgent();
    final result = await client.send(
      InternetAddress.loopbackIPv4,
      agent.port,
      key,
      AgentCommand.status,
    );
    expect(result.outcome, AgentCallOutcome.accepted);
    expect(result.response!.result, 'awake');
    expect(agent.received, [AgentCommand.status]);
  });

  test('una clave distinta se informa como no autorizada', () async {
    final agent = await startAgent();
    final result = await client.send(
      InternetAddress.loopbackIPv4,
      agent.port,
      AgentKey.generate(),
      AgentCommand.shutdown,
    );
    expect(result.outcome, AgentCallOutcome.unauthorized);
    expect(agent.received, isEmpty);
  });

  test('un fallo del PC se informa como rechazado', () async {
    final agent = await startAgent(fail: true);
    final result = await client.send(
      InternetAddress.loopbackIPv4,
      agent.port,
      key,
      AgentCommand.shutdown,
    );
    expect(result.outcome, AgentCallOutcome.rejected);
    expect(result.message, contains('no pudo ejecutar'));
  });

  test('sin agente escuchando el resultado es inalcanzable', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = server.port;
    await server.close();
    final result = await client.send(
      InternetAddress.loopbackIPv4,
      port,
      key,
      AgentCommand.status,
    );
    expect(result.outcome, AgentCallOutcome.unreachable);
  });

  test('sin respuesta tras enviar la orden el resultado es interrumpido', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);
    // Acepta y lee la orden, pero nunca responde ni cierra.
    server.listen((socket) => socket.listen((_) {}));
    final result = await client.send(
      InternetAddress.loopbackIPv4,
      server.port,
      key,
      AgentCommand.suspend,
    );
    expect(result.outcome, AgentCallOutcome.interrupted);
  });

  group('PowerControlService', () {
    test('usa la clave guardada y la IPv4 local', () async {
      final agent = await startAgent();
      final keys = InMemoryAgentKeyStore()..keys['pc-1'] = key;
      final service = PowerControlService(client: client, keyStore: keys);
      final result = await service.run(
        sampleDevice(localIpv4: '127.0.0.1', agentPort: agent.port),
        AgentCommand.status,
      );
      expect(result.isAccepted, isTrue);
    });

    test('si la IPv4 local no conecta, usa la IPv6 (fuera de casa)', () async {
      final ipv6Agent = await startAgent(address: InternetAddress.loopbackIPv6);
      final keys = InMemoryAgentKeyStore()..keys['pc-1'] = key;
      final service = PowerControlService(client: client, keyStore: keys);
      final result = await service.run(
        sampleDevice(
          localIpv4: '127.0.0.1',
          ipv6Address: '::1',
          agentPort: ipv6Agent.port,
        ),
        AgentCommand.status,
      );
      expect(result.isAccepted, isTrue);
      expect(ipv6Agent.received, [AgentCommand.status]);
    });

    test('si la orden llegó por IPv4 no la repite por IPv6', () async {
      final ipv6Agent = await startAgent(address: InternetAddress.loopbackIPv6);
      final ipv4Agent = await startAgent(fail: true, port: ipv6Agent.port);
      final keys = InMemoryAgentKeyStore()..keys['pc-1'] = key;
      final service = PowerControlService(client: client, keyStore: keys);
      final result = await service.run(
        sampleDevice(
          localIpv4: '127.0.0.1',
          ipv6Address: '::1',
          agentPort: ipv6Agent.port,
        ),
        AgentCommand.shutdown,
      );
      expect(result.outcome, AgentCallOutcome.rejected);
      expect(ipv4Agent.received, [AgentCommand.shutdown]);
      expect(ipv6Agent.received, isEmpty);
    });

    test('sin clave guardada no conecta', () async {
      final service = PowerControlService(
        client: client,
        keyStore: InMemoryAgentKeyStore(),
      );
      final result = await service.run(
        sampleDevice(agentPort: 47123),
        AgentCommand.shutdown,
      );
      expect(result.outcome, AgentCallOutcome.unauthorized);
    });

    test('sin puerto de agente informa que no está configurado', () async {
      final service = PowerControlService(
        client: client,
        keyStore: InMemoryAgentKeyStore(),
      );
      final result = await service.run(sampleDevice(), AgentCommand.status);
      expect(result.message, contains('no tiene agente'));
    });
  });
}
