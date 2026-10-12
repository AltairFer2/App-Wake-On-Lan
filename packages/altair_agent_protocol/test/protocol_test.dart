import 'dart:convert';

import 'package:altair_agent_protocol/altair_agent_protocol.dart';
import 'package:test/test.dart';

void main() {
  final key = AgentKey.generate();
  final now = DateTime.utc(2026, 10, 11, 20, 0);

  AgentRequest verify(String line, {DateTime? at, ReplayGuard? guard}) =>
      AgentRequest.decodeAndVerify(
        line,
        key,
        now: at ?? now,
        replayGuard: guard ?? ReplayGuard(),
      );

  Matcher throwsCode(AgentErrorCode code) => throwsA(
    isA<AgentProtocolException>().having((e) => e.code, 'code', code),
  );

  group('AgentKey', () {
    test('se codifica en 43 caracteres base64url y se recupera', () {
      final encoded = key.encode();
      expect(encoded, hasLength(43));
      expect(encoded, matches(RegExp(r'^[A-Za-z0-9_-]+$')));
      expect(AgentKey.parse(encoded).sign('x'), key.sign('x'));
    });

    test('rechaza longitudes y caracteres inválidos', () {
      expect(() => AgentKey.parse('corta'), throwsFormatException);
      expect(() => AgentKey.parse('!' * 43), throwsFormatException);
      expect(AgentKey.tryParse(''), isNull);
    });

    test('toString no revela la clave', () {
      expect(key.toString(), isNot(contains(key.encode())));
    });

    test('verify rechaza firmas alteradas', () {
      final signature = key.sign('mensaje');
      expect(key.verify('mensaje', signature), isTrue);
      expect(key.verify('mensaje2', signature), isFalse);
      expect(key.verify('mensaje', signature.substring(1)), isFalse);
      expect(AgentKey.generate().verify('mensaje', signature), isFalse);
    });
  });

  group('AgentRequest', () {
    test('ida y vuelta con la misma clave', () {
      final request = AgentRequest.create(AgentCommand.shutdown, now);
      final decoded = verify(request.encode(key));
      expect(decoded.command, AgentCommand.shutdown);
      expect(decoded.nonce, request.nonce);
    });

    test('una clave distinta es no autorizada', () {
      final line = AgentRequest.create(AgentCommand.status, now)
          .encode(AgentKey.generate());
      expect(() => verify(line), throwsCode(AgentErrorCode.unauthorized));
    });

    test('alterar la orden invalida la firma', () {
      final line = AgentRequest.create(AgentCommand.status, now).encode(key);
      final tampered = line.replaceFirst('"status"', '"shutdown"');
      expect(() => verify(tampered), throwsCode(AgentErrorCode.unauthorized));
    });

    test('fuera de la ventana de 30 s es desfase de reloj', () {
      final line = AgentRequest.create(AgentCommand.status, now).encode(key);
      expect(
        () => verify(line, at: now.add(const Duration(seconds: 31))),
        throwsCode(AgentErrorCode.clockSkew),
      );
      expect(
        verify(line, at: now.subtract(const Duration(seconds: 29))).command,
        AgentCommand.status,
      );
    });

    test('una petición repetida se rechaza', () {
      final guard = ReplayGuard();
      final line = AgentRequest.create(AgentCommand.suspend, now).encode(key);
      verify(line, guard: guard);
      expect(() => verify(line, guard: guard), throwsCode(AgentErrorCode.replay));
    });

    test('mensajes mal formados o enormes son bad_request', () {
      for (final line in [
        'no json',
        '[]',
        '{}',
        jsonEncode({'v': 1, 'cmd': 'format_c', 'ts': 1, 'nonce': 'a' * 32, 'sig': ''}),
        jsonEncode({'v': 2, 'cmd': 'status', 'ts': 1, 'nonce': 'a' * 32, 'sig': ''}),
        jsonEncode({'v': 1, 'cmd': 'status', 'ts': 1, 'nonce': 'corto', 'sig': ''}),
        'x' * (maxMessageBytes + 1),
      ]) {
        expect(() => verify(line), throwsCode(AgentErrorCode.badRequest), reason: line);
      }
    });
  });

  group('ReplayGuard', () {
    test('olvida los nonces fuera de la ventana', () {
      final guard = ReplayGuard(window: const Duration(seconds: 10));
      expect(guard.accept('n', now), isTrue);
      expect(guard.accept('n', now.add(const Duration(seconds: 5))), isFalse);
      expect(guard.accept('n', now.add(const Duration(seconds: 11))), isTrue);
    });

    test('respeta el límite de entradas', () {
      final guard = ReplayGuard(maxEntries: 2);
      guard.accept('a', now);
      guard.accept('b', now);
      guard.accept('c', now);
      expect(guard.accept('a', now), isTrue);
    });
  });

  group('AgentResponse', () {
    final request = AgentRequest.create(AgentCommand.status, now);
    final response = AgentResponse(
      requestNonce: request.nonce,
      ok: true,
      agentTime: now,
      result: 'awake',
    );

    test('ida y vuelta vinculada al nonce de la petición', () {
      final decoded = AgentResponse.decodeAndVerify(
        response.encode(key),
        key,
        expectedNonce: request.nonce,
      );
      expect(decoded.ok, isTrue);
      expect(decoded.result, 'awake');
    });

    test('rechaza respuestas de otra petición o con otra clave', () {
      expect(
        () => AgentResponse.decodeAndVerify(
          response.encode(key),
          key,
          expectedNonce: generateNonce(),
        ),
        throwsCode(AgentErrorCode.unauthorized),
      );
      expect(
        () => AgentResponse.decodeAndVerify(
          response.encode(AgentKey.generate()),
          key,
          expectedNonce: request.nonce,
        ),
        throwsCode(AgentErrorCode.unauthorized),
      );
    });

    test('transporta códigos de error', () {
      final error = AgentResponse(
        requestNonce: request.nonce,
        ok: false,
        agentTime: now,
        error: AgentErrorCode.clockSkew,
      );
      final decoded = AgentResponse.decodeAndVerify(
        error.encode(key),
        key,
        expectedNonce: request.nonce,
      );
      expect(decoded.error, AgentErrorCode.clockSkew);
    });
  });
}
