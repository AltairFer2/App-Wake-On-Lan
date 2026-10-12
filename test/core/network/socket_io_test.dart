import 'dart:async';
import 'dart:io';

import 'package:altair_wake/core/network/mac_address.dart';
import 'package:altair_wake/core/network/magic_packet.dart';
import 'package:altair_wake/core/network/reachability_probe.dart';
import 'package:altair_wake/core/network/socket_failure.dart';
import 'package:altair_wake/core/network/udp_sender.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fakes.dart';

/// Pruebas con sockets reales sobre loopback: verifican el envío UDP y el
/// sondeo TCP sin depender de la red física.
void main() {
  group('RawDatagramUdpSender', () {
    test('entrega los 102 bytes del paquete mágico a un receptor local', () async {
      final receiver = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(receiver.close);
      final received = Completer<Datagram>();
      receiver.listen((event) {
        if (event != RawSocketEvent.read) return;
        final datagram = receiver.receive();
        if (datagram != null && !received.isCompleted) received.complete(datagram);
      });

      final packet = MagicPacket.build(MacAddress.parse('D8:BB:C1:0A:FF:01'));
      await const RawDatagramUdpSender().send(
        packet,
        InternetAddress.loopbackIPv4,
        receiver.port,
      );

      final datagram = await received.future.timeout(const Duration(seconds: 5));
      expect(datagram.data, packet);
    });
  });

  group('TcpReachabilityProbe', () {
    test('reachable cuando el puerto acepta la conexión', () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);
      server.listen((socket) => socket.destroy());

      final result = await const TcpReachabilityProbe().probe(
        InternetAddress.loopbackIPv4,
        server.port,
      );
      expect(result.status, ReachabilityStatus.reachable);
    });

    test('reachable cuando el host rechaza la conexión (puerto cerrado)', () async {
      // Reserva un puerto libre y lo cierra para provocar un rechazo.
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final closedPort = server.port;
      await server.close();

      final result = await const TcpReachabilityProbe(
        timeout: Duration(seconds: 5),
      ).probe(InternetAddress.loopbackIPv4, closedPort);
      expect(result.status, ReachabilityStatus.reachable);
      expect(result.detail, contains('rechazó'));
    });
  });

  group('classifySocketFailure', () {
    test('códigos POSIX (Android)', () {
      expect(
        classifySocketFailure(socketError(101), isWindows: false),
        SocketFailureKind.networkUnreachable,
      );
      expect(
        classifySocketFailure(socketError(113), isWindows: false),
        SocketFailureKind.hostUnreachable,
      );
      expect(
        classifySocketFailure(socketError(111), isWindows: false),
        SocketFailureKind.connectionRefused,
      );
      expect(
        classifySocketFailure(socketError(13), isWindows: false),
        SocketFailureKind.permissionDenied,
      );
      expect(
        classifySocketFailure(socketError(9999), isWindows: false),
        SocketFailureKind.other,
      );
    });

    test('códigos WSA (Windows)', () {
      expect(
        classifySocketFailure(socketError(10051), isWindows: true),
        SocketFailureKind.networkUnreachable,
      );
      expect(
        classifySocketFailure(socketError(10061), isWindows: true),
        SocketFailureKind.connectionRefused,
      );
      // Código Win32 que Dart reporta al rechazarse un Socket.connect.
      expect(
        classifySocketFailure(socketError(1225), isWindows: true),
        SocketFailureKind.connectionRefused,
      );
    });

    test('timeout sin código del sistema', () {
      expect(
        classifySocketFailure(const SocketException('Connection timed out')),
        SocketFailureKind.timedOut,
      );
    });
  });
}
