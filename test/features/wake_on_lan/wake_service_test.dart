import 'dart:io';

import 'package:altair_wake/core/network/magic_packet.dart';
import 'package:altair_wake/core/network/udp_sender.dart';
import 'package:altair_wake/features/devices/domain/device.dart';
import 'package:altair_wake/features/wake_on_lan/domain/wake_report.dart';
import 'package:altair_wake/features/wake_on_lan/domain/wake_service.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fakes.dart';

void main() {
  late FakeUdpSender sender;
  late FakeAddressResolver resolver;
  late WakeService service;

  setUp(() {
    sender = FakeUdpSender();
    resolver = FakeAddressResolver();
    service = WakeService(
      sender: sender,
      resolver: resolver,
      repetitionGap: Duration.zero,
    );
  });

  test('LAN: envía el paquete de 102 bytes por difusión, 3 veces', () async {
    final report = await service.wake(sampleDevice());

    expect(report.routes, hasLength(1));
    final route = report.routes.single;
    expect(route.kind, WakeRouteKind.lanBroadcast);
    expect(route.outcome, WakeRouteOutcome.sent);
    expect(route.target, '192.168.100.255:9');
    expect(sender.sent, hasLength(3));
    for (final datagram in sender.sent) {
      expect(datagram.payload, MagicPacket.build(sampleDevice().mac));
      expect(datagram.destination.address, '192.168.100.255');
      expect(datagram.port, 9);
      expect(datagram.broadcast, isTrue);
    }
    expect(report.status, WakeAttemptStatus.sent);
  });

  test('una difusión no IPv4 es una dirección inválida y no se envía', () async {
    final report = await service.wake(sampleDevice(broadcastAddress: 'ff02::1'));
    expect(report.routes.single.outcome, WakeRouteOutcome.invalidAddress);
    expect(sender.sent, isEmpty);
    expect(report.status, WakeAttemptStatus.notSent);
  });

  test('error de socket sin ruta se reporta como sin conectividad', () async {
    sender.failures['192.168.100.255'] = socketError(
      Platform.isWindows ? 10051 : 101,
    );
    final report = await service.wake(sampleDevice());
    expect(report.routes.single.outcome, WakeRouteOutcome.noConnectivity);
    expect(report.anySent, isFalse);
  });

  test('otros errores de socket se reportan como error de socket', () async {
    sender.failures['192.168.100.255'] = socketError(
      Platform.isWindows ? 10013 : 13,
      'Permission denied',
    );
    final report = await service.wake(sampleDevice());
    expect(report.routes.single.outcome, WakeRouteOutcome.socketError);
    expect(report.routes.single.detail, contains('Permission denied'));
  });

  test('UdpSendException se reporta como error de socket', () async {
    sender.failures['192.168.100.255'] = const UdpSendException('cola llena');
    final report = await service.wake(sampleDevice());
    expect(report.routes.single.outcome, WakeRouteOutcome.socketError);
  });

  group('WAN IPv4', () {
    test('envía por unicast a una IPv4 pública resuelta por DNS', () async {
      resolver.records['casa.example.net'] = [InternetAddress('203.0.113.7')];
      final report = await service.wake(
        sampleDevice(
          remoteMode: RemoteAccessMode.ipv4,
          remoteHost: 'casa.example.net',
        ),
      );
      expect(report.routes, hasLength(2));
      final wan = report.routes.last;
      expect(wan.kind, WakeRouteKind.wanIpv4);
      expect(wan.outcome, WakeRouteOutcome.sent);
      final unicast = sender.sent.where((d) => !d.broadcast).toList();
      expect(unicast, hasLength(3));
      expect(unicast.first.destination.address, '203.0.113.7');
    });

    test('una IPv4 privada (CGNAT/RFC 1918) no se envía: posible bloqueo NAT', () async {
      for (final ip in ['10.85.101.80', '100.64.12.1']) {
        sender.sent.clear();
        final report = await service.wake(
          sampleDevice(remoteMode: RemoteAccessMode.ipv4, remoteHost: ip),
        );
        expect(report.routes.last.outcome, WakeRouteOutcome.likelyBlockedByNat, reason: ip);
        expect(sender.sent.where((d) => !d.broadcast), isEmpty);
        expect(report.status, WakeAttemptStatus.partiallySent);
      }
    });

    test('un fallo DNS se reporta como error de resolución', () async {
      final report = await service.wake(
        sampleDevice(
          remoteMode: RemoteAccessMode.ipv4,
          remoteHost: 'no-existe.example.net',
        ),
      );
      expect(report.routes.last.outcome, WakeRouteOutcome.dnsFailure);
    });

    test('sin host remoto es una dirección inválida', () async {
      final report = await service.wake(
        sampleDevice(remoteMode: RemoteAccessMode.ipv4),
      );
      expect(report.routes.last.outcome, WakeRouteOutcome.invalidAddress);
    });
  });

  group('WAN IPv6', () {
    test('usa la IPv6 global del equipo si no hay host remoto', () async {
      final report = await service.wake(
        sampleDevice(
          remoteMode: RemoteAccessMode.ipv6,
          ipv6Address: '2806:2f0:1234::10',
        ),
      );
      final wan = report.routes.last;
      expect(wan.kind, WakeRouteKind.wanIpv6);
      expect(wan.outcome, WakeRouteOutcome.sent);
      expect(wan.target, '[2806:2f0:1234::10]:9');
      expect(resolver.queried, ['2806:2f0:1234::10']);
    });

    test('prefiere el host remoto (AAAA) si está configurado', () async {
      resolver.records['pc.example.net'] = [InternetAddress('2806:2f0:aaaa::1')];
      final report = await service.wake(
        sampleDevice(
          remoteMode: RemoteAccessMode.ipv6,
          remoteHost: 'pc.example.net',
          ipv6Address: '2806:2f0:1234::10',
        ),
      );
      expect(report.routes.last.target, '[2806:2f0:aaaa::1]:9');
    });

    test('rechaza IPv6 link-local como destino remoto', () async {
      final report = await service.wake(
        sampleDevice(remoteMode: RemoteAccessMode.ipv6, remoteHost: 'fe80::1'),
      );
      expect(report.routes.last.outcome, WakeRouteOutcome.invalidAddress);
    });

    test('rechaza IPv6 ULA como destino remoto (privada)', () async {
      final report = await service.wake(
        sampleDevice(remoteMode: RemoteAccessMode.ipv6, remoteHost: 'fd00::1'),
      );
      expect(report.routes.last.outcome, WakeRouteOutcome.likelyBlockedByNat);
    });
  });
}
