import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:altair_agent_protocol/altair_agent_protocol.dart';
import 'package:test/test.dart';

void main() {
  final key = AgentKey.generate();
  final keys = TunnelKeys.derive(key, 'a' * 32);

  Future<List<int>> roundTrip(List<List<int>> chunks) async {
    final framed = await encodeTunnelFrames(
      Stream.fromIterable(chunks),
      keys.appToAgent,
    ).toList();
    final decoded = await decodeTunnelFrames(
      Stream.fromIterable(framed),
      keys.appToAgent,
    ).toList();
    return [for (final chunk in decoded) ...chunk];
  }

  Future<List<int>> frames(List<int> data) async => [
    for (final frame in await encodeTunnelFrames(Stream.value(data), keys.appToAgent).toList())
      ...frame,
  ];

  group('TunnelKeys', () {
    test('una clave por sentido y por sesión', () {
      final other = TunnelKeys.derive(key, 'b' * 32);
      expect(keys.appToAgent, isNot(keys.agentToApp));
      expect(keys.appToAgent, isNot(other.appToAgent));
      expect(TunnelKeys.derive(key, 'a' * 32).appToAgent, keys.appToAgent);
      expect(keys.toString(), isNot(contains(base64.encode(keys.appToAgent))));
    });
  });

  group('tramas', () {
    test('ida y vuelta conserva los datos, también los grandes', () async {
      final big = List<int>.generate(maxTunnelPayload * 2 + 10, (i) => i % 251);
      expect(await roundTrip([utf8.encode('hola'), big]), [...utf8.encode('hola'), ...big]);
    });

    test('las tramas pueden llegar partidas o juntas', () async {
      final framed = await encodeTunnelFrames(
        Stream.fromIterable([utf8.encode('uno'), utf8.encode('dos')]),
        keys.appToAgent,
      ).toList();
      final pieces = [for (final frame in framed) for (final byte in frame) [byte]];
      final decoded = await decodeTunnelFrames(Stream.fromIterable(pieces), keys.appToAgent).toList();
      expect(utf8.decode([for (final chunk in decoded) ...chunk]), 'unodos');
    });

    test('un byte alterado se rechaza', () async {
      final bytes = await frames(utf8.encode('secreto'));
      bytes[6] ^= 1;
      expect(
        decodeTunnelFrames(Stream.value(bytes), keys.appToAgent).toList(),
        throwsA(isA<TunnelIntegrityException>()),
      );
    });

    test('la clave del otro sentido no sirve', () async {
      final bytes = await frames(utf8.encode('x'));
      expect(
        decodeTunnelFrames(Stream.value(bytes), keys.agentToApp).toList(),
        throwsA(isA<TunnelIntegrityException>()),
      );
    });

    test('repetir o reordenar tramas se rechaza', () async {
      final first = await frames(utf8.encode('a'));
      expect(
        decodeTunnelFrames(Stream.fromIterable([first, first]), keys.appToAgent).toList(),
        throwsA(isA<TunnelIntegrityException>()),
      );
    });

    test('una longitud fuera de rango se rechaza sin esperar datos', () async {
      final header = Uint8List(4)..buffer.asByteData().setUint32(0, maxTunnelPayload + 1);
      expect(
        decodeTunnelFrames(Stream.value(header), keys.appToAgent).toList(),
        throwsA(isA<TunnelIntegrityException>()),
      );
    });

    test('cortar a mitad de una trama se informa', () async {
      final bytes = await frames(utf8.encode('incompleto'));
      expect(
        decodeTunnelFrames(Stream.value(bytes.sublist(0, 10)), keys.appToAgent).toList(),
        throwsA(isA<TunnelIntegrityException>()),
      );
    });
  });

  group('readFirstLine', () {
    test('separa la línea de los datos que la siguen', () async {
      final input = Stream.fromIterable([
        utf8.encode('{"v":1}'),
        utf8.encode('\nresto'),
        utf8.encode(' final'),
      ]);
      final first = await readFirstLine(input, timeout: const Duration(seconds: 1));
      expect(first.line, '{"v":1}');
      expect(utf8.decode(await first.rest.expand((chunk) => chunk).toList()), 'resto final');
    });

    test('null si la línea no termina a tiempo', () async {
      final input = StreamController<List<int>>()..add(utf8.encode('sin salto'));
      final first = await readFirstLine(input.stream, timeout: const Duration(milliseconds: 50));
      expect(first.line, isNull);
      await input.close();
    });

    test('null si la línea supera el tamaño máximo', () async {
      final input = Stream.value(List<int>.filled(maxMessageBytes + 1, 0x61));
      final first = await readFirstLine(input, timeout: const Duration(seconds: 1));
      expect(first.line, isNull);
    });
  });
}
