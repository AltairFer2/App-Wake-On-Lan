import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:altair_agent_protocol/altair_agent_protocol.dart';
import 'package:altair_wake_agent/altair_wake_agent.dart';
import 'package:test/test.dart';

class FakePowerActions implements PowerActions {
  final List<String> calls = [];
  bool failShutdown = false;

  @override
  Future<void> scheduleShutdown() async {
    if (failShutdown) throw const PowerActionException('simulado');
    calls.add('shutdown');
  }

  @override
  Future<void> cancelShutdown() async => calls.add('cancel');

  @override
  Future<void> suspend() async => calls.add('suspend');

  @override
  Future<void> keepDisplayOn() async => calls.add('display');
}

void main() {
  final key = AgentKey.generate();
  final now = DateTime.utc(2026, 10, 11, 21);
  late FakePowerActions actions;
  late RequestHandler handler;

  setUp(() {
    actions = FakePowerActions();
    handler = RequestHandler(key: key, actions: actions, clock: () => now);
  });

  AgentResponse responseOf(HandledRequest handled, AgentRequest request) =>
      AgentResponse.decodeAndVerify(
        handled.response!,
        key,
        expectedNonce: request.nonce,
      );

  group('RequestHandler', () {
    test('status responde awake sin ejecutar acciones', () async {
      final request = AgentRequest.create(AgentCommand.status, now);
      final handled = await handler.handle(request.encode(key), '192.168.100.19');
      expect(responseOf(handled, request).result, 'awake');
      expect(handled.afterResponse, isNull);
      expect(actions.calls, isEmpty);
    });

    test('shutdown se ejecuta antes de responder', () async {
      final request = AgentRequest.create(AgentCommand.shutdown, now);
      final handled = await handler.handle(request.encode(key), 'x');
      expect(actions.calls, ['shutdown']);
      expect(responseOf(handled, request).ok, isTrue);
    });

    test('display mantiene la pantalla antes de responder', () async {
      final request = AgentRequest.create(AgentCommand.wakeDisplay, now);
      final handled = await handler.handle(request.encode(key), 'x');
      expect(actions.calls, ['display']);
      expect(responseOf(handled, request).result, 'accepted');
      expect(handled.afterResponse, isNull);
    });

    test('un fallo de shutdown.exe se informa como failed', () async {
      actions.failShutdown = true;
      final request = AgentRequest.create(AgentCommand.shutdown, now);
      final response = responseOf(
        await handler.handle(request.encode(key), 'x'),
        request,
      );
      expect(response.ok, isFalse);
      expect(response.error, AgentErrorCode.failed);
    });

    test('suspend responde primero y difiere la acción', () async {
      final request = AgentRequest.create(AgentCommand.suspend, now);
      final handled = await handler.handle(request.encode(key), 'x');
      expect(actions.calls, isEmpty);
      expect(responseOf(handled, request).result, 'accepted');
      await handled.afterResponse!();
      expect(actions.calls, ['suspend']);
    });

    test('una clave incorrecta no ejecuta nada ni recibe respuesta', () async {
      final request = AgentRequest.create(AgentCommand.shutdown, now);
      final handled = await handler.handle(
        request.encode(AgentKey.generate()),
        'x',
      );
      expect(actions.calls, isEmpty);
      expect(handled.response, isNull);
    });

    test('una petición mal formada no recibe respuesta', () async {
      final handled = await handler.handle('{}', 'x');
      expect(handled.response, isNull);
    });

    test('con firma válida, el desfase de reloj se informa firmado', () async {
      final request = AgentRequest.create(
        AgentCommand.status,
        now.subtract(const Duration(minutes: 5)),
      );
      final handled = await handler.handle(request.encode(key), 'x');
      expect(responseOf(handled, request).error, AgentErrorCode.clockSkew);
    });

    test('bloquea al origen tras 10 fallos y deja de responder', () async {
      final bad = AgentRequest.create(AgentCommand.shutdown, now)
          .encode(AgentKey.generate());
      for (var i = 0; i < 10; i++) {
        await handler.handle(bad, '10.0.0.66');
      }
      final valid = AgentRequest.create(AgentCommand.shutdown, now).encode(key);
      final blocked = await handler.handle(valid, '10.0.0.66');
      expect(blocked.response, isNull);
      expect(actions.calls, isEmpty);
      // Otro origen no queda afectado.
      await handler.handle(valid, '192.168.100.19');
      expect(actions.calls, ['shutdown']);
    });
  });

  group('FailureRateLimiter', () {
    test('el bloqueo expira', () {
      final limiter = FailureRateLimiter(maxFailures: 2);
      limiter.recordFailure('a', now);
      limiter.recordFailure('a', now);
      expect(limiter.isBlocked('a', now), isTrue);
      expect(limiter.isBlocked('a', now.add(const Duration(minutes: 6))), isFalse);
    });

    test('los fallos fuera de la ventana no cuentan', () {
      final limiter = FailureRateLimiter(maxFailures: 2);
      limiter.recordFailure('a', now);
      limiter.recordFailure('a', now.add(const Duration(minutes: 2)));
      expect(limiter.isBlocked('a', now.add(const Duration(minutes: 2))), isFalse);
    });
  });

  group('AgentServer (loopback)', () {
    late AgentServer server;

    setUp(() async {
      server = AgentServer(
        handler: RequestHandler(key: key, actions: actions),
        logger: AgentLogger(null),
        port: 0,
        actionDelay: Duration.zero,
        readTimeout: const Duration(seconds: 1),
      );
      await server.start();
    });

    tearDown(() => server.close());

    Future<String> exchange(String payload) async {
      final socket = await Socket.connect(InternetAddress.loopbackIPv4, server.boundPort);
      socket.write(payload);
      await socket.flush();
      final reply = await utf8.decoder.bind(socket).join();
      socket.destroy();
      return reply.trim();
    }

    test('responde a una petición firmada por IPv4', () async {
      final request = AgentRequest.create(AgentCommand.status, DateTime.now());
      final reply = await exchange('${request.encode(key)}\n');
      final response = AgentResponse.decodeAndVerify(
        reply,
        key,
        expectedNonce: request.nonce,
      );
      expect(response.result, 'awake');
    });

    test('también escucha por IPv6', () async {
      final request = AgentRequest.create(AgentCommand.status, DateTime.now());
      final socket = await Socket.connect(InternetAddress.loopbackIPv6, server.boundPort);
      socket.write('${request.encode(key)}\n');
      final reply = await utf8.decoder.bind(socket).join();
      socket.destroy();
      expect(
        AgentResponse.decodeAndVerify(reply.trim(), key, expectedNonce: request.nonce).ok,
        isTrue,
      );
    });

    test('ejecuta la suspensión después de responder', () async {
      final request = AgentRequest.create(AgentCommand.suspend, DateTime.now());
      await exchange('${request.encode(key)}\n');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(actions.calls, ['suspend']);
    });

    test('cierra sin responder si no llega una línea completa', () async {
      expect(await exchange('{"v":1'), isEmpty);
    });

    test('cierra sin responder si la línea supera el límite', () async {
      expect(await exchange('${'x' * (maxMessageBytes + 10)}\n'), isEmpty);
    });
  });

  group('Túnel de escritorio remoto', () {
    /// Hace de RDP: devuelve en mayúsculas lo que recibe.
    late ServerSocket fakeRdp;
    late RequestHandler tunnelHandler;
    late AgentServer server;

    setUp(() async {
      fakeRdp = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      fakeRdp.listen(
        (socket) => socket
            .addStream(socket.map((chunk) => utf8.encode(utf8.decode(chunk).toUpperCase())))
            .then((_) => socket.close()),
      );
      tunnelHandler = RequestHandler(
        key: key,
        actions: actions,
        remoteDesktop: localRemoteDesktop(fakeRdp.port),
      );
      server = AgentServer(
        handler: tunnelHandler,
        logger: AgentLogger(null),
        port: 0,
        readTimeout: const Duration(seconds: 1),
      );
      await server.start();
    });

    tearDown(() async {
      await server.close();
      await fakeRdp.close();
    });

    /// Abre el túnel como lo hace la app y devuelve lo necesario para usarlo.
    Future<({Socket socket, AgentResponse response, Stream<List<int>> fromAgent, TunnelKeys keys})>
    openTunnel([AgentKey? signingKey]) async {
      final request = AgentRequest.create(AgentCommand.remoteDesktop, DateTime.now());
      final socket = await Socket.connect(InternetAddress.loopbackIPv4, server.boundPort);
      socket.write('${request.encode(signingKey ?? key)}\n');
      await socket.flush();
      final first = await readFirstLine(socket, timeout: const Duration(seconds: 2));
      final response = AgentResponse.decodeAndVerify(
        first.line!,
        key,
        expectedNonce: request.nonce,
      );
      return (
        socket: socket,
        response: response,
        fromAgent: first.rest,
        keys: TunnelKeys.derive(key, request.nonce),
      );
    }

    test('los datos viajan en tramas autenticadas hasta RDP y de vuelta', () async {
      final tunnel = await openTunnel();
      expect(tunnel.response.result, tunnelResult);

      final toAgent = StreamController<List<int>>();
      unawaited(tunnel.socket.addStream(encodeTunnelFrames(toAgent.stream, tunnel.keys.appToAgent)));
      final replies = decodeTunnelFrames(tunnel.fromAgent, tunnel.keys.agentToApp);
      toAgent.add(utf8.encode('hola'));
      expect(utf8.decode(await replies.first), 'HOLA');

      await toAgent.close();
      tunnel.socket.destroy();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(tunnelHandler.activeTunnels, 0);
    });

    test('una trama alterada cierra el túnel', () async {
      final tunnel = await openTunnel();
      final frame = [
        for (final part in await encodeTunnelFrames(
          Stream.value(utf8.encode('hola')),
          tunnel.keys.appToAgent,
        ).toList())
          ...part,
      ];
      frame[5] ^= 0xFF;
      tunnel.socket.add(frame);
      await tunnel.socket.flush();
      // El agente corta sin devolver nada.
      expect(await tunnel.fromAgent.toList(), isEmpty);
      tunnel.socket.destroy();
      expect(tunnelHandler.activeTunnels, 0);
    });

    test('sin la clave no se abre ni se responde', () async {
      final request = AgentRequest.create(AgentCommand.remoteDesktop, DateTime.now());
      final socket = await Socket.connect(InternetAddress.loopbackIPv4, server.boundPort);
      socket.write('${request.encode(AgentKey.generate())}\n');
      expect(await socket.toList(), isEmpty);
      socket.destroy();
      expect(tunnelHandler.activeTunnels, 0);
    });

    test('sin escritorio remoto en el PC responde failed', () async {
      final unavailable = RequestHandler(
        key: key,
        actions: actions,
        clock: () => now,
        remoteDesktop: () => throw const SocketException('Connection refused'),
      );
      final request = AgentRequest.create(AgentCommand.remoteDesktop, now);
      final handled = await unavailable.handle(request.encode(key), 'x');
      expect(responseOf(handled, request).error, AgentErrorCode.failed);
      expect(handled.tunnel, isNull);
    });

    test('limita las sesiones simultáneas', () async {
      final limited = RequestHandler(
        key: key,
        actions: actions,
        clock: () => now,
        remoteDesktop: localRemoteDesktop(fakeRdp.port),
      );
      final opened = <AgentTunnel>[];
      for (var i = 0; i < RequestHandler.maxTunnels; i++) {
        final request = AgentRequest.create(AgentCommand.remoteDesktop, now);
        opened.add((await limited.handle(request.encode(key), 'x')).tunnel!);
      }
      final extra = AgentRequest.create(AgentCommand.remoteDesktop, now);
      final refused = await limited.handle(extra.encode(key), 'x');
      expect(refused.tunnel, isNull);
      expect(responseOf(refused, extra).error, AgentErrorCode.failed);

      for (final tunnel in opened) {
        tunnel
          ..release()
          ..release()
          ..remoteDesktop.destroy();
      }
      expect(limited.activeTunnels, 0);
    });
  });
}
