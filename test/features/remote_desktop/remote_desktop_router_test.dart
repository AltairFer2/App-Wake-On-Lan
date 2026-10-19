import 'dart:io';

import 'package:altair_agent_protocol/altair_agent_protocol.dart';
import 'package:altair_wake/features/remote_desktop/data/rdp_tunnel.dart';
import 'package:altair_wake/features/remote_desktop/domain/remote_desktop_router.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fakes.dart';

void main() {
  late InMemoryAgentKeyStore keyStore;
  late List<String> tunnelAttempts;
  late int closedTunnels;

  final pc = sampleDevice(
    remoteDesktopPort: 3389,
    agentPort: 47123,
    ipv6Address: '2001:db8::20',
  );

  setUp(() {
    keyStore = InMemoryAgentKeyStore();
    keyStore.keys[pc.id] = AgentKey.generate();
    tunnelAttempts = [];
    closedTunnels = 0;
  });

  RemoteDesktopRouter router({
    required bool atHome,
    Map<String, RdpTunnelException> failures = const {},
  }) => RemoteDesktopRouter(
    keyStore: keyStore,
    probe: (_, _) async => atHome,
    openTunnel: (agent, agentPort, key, localPort) async {
      tunnelAttempts.add(agent.address);
      final failure = failures[agent.address];
      if (failure != null) throw failure;
      return (localPort: localPort, close: () async => closedTunnels++);
    },
  );

  test('en casa conecta directo a la IPv4 local', () async {
    final endpoint = await router(atHome: true).connect(pc);
    expect((endpoint.host, endpoint.port, endpoint.viaAgent), ('192.168.100.20', 3389, false));
    expect(tunnelAttempts, isEmpty);
  });

  test('fuera de casa abre el túnel en un puerto local estable', () async {
    final endpoint = await router(atHome: false).connect(pc);
    expect(endpoint.viaAgent, isTrue);
    expect(endpoint.host, InternetAddress.loopbackIPv4.address);
    expect(endpoint.port, tunnelLocalPortFor(pc.id));
    await endpoint.close();
    expect(closedTunnels, 1);
  });

  test('si el agente no responde por IPv4 prueba por IPv6', () async {
    final endpoint = await router(
      atHome: false,
      failures: {
        '192.168.100.20': const RdpTunnelException(RdpTunnelFailure.unreachable, 'sin ruta'),
      },
    ).connect(pc);
    expect(endpoint.viaAgent, isTrue);
    expect(tunnelAttempts, ['192.168.100.20', '2001:db8::20']);
  });

  test('un rechazo del agente no se reintenta por otra dirección', () async {
    await expectLater(
      router(
        atHome: false,
        failures: {
          '192.168.100.20': const RdpTunnelException(RdpTunnelFailure.rejected, 'RDP apagado'),
        },
      ).connect(pc),
      throwsA(
        isA<RemoteDesktopRouteException>().having((e) => e.message, 'message', 'RDP apagado'),
      ),
    );
    expect(tunnelAttempts, ['192.168.100.20']);
  });

  test('sin ninguna ruta lo explica', () async {
    const unreachable = RdpTunnelException(RdpTunnelFailure.unreachable, 'x');
    await expectLater(
      router(
        atHome: false,
        failures: {'192.168.100.20': unreachable, '2001:db8::20': unreachable},
      ).connect(pc),
      throwsA(
        isA<RemoteDesktopRouteException>().having((e) => e.message, 'message', contains('WARP')),
      ),
    );
  });

  test('fuera de casa sin agente configurado no intenta el túnel', () async {
    final withoutAgent = sampleDevice(remoteDesktopPort: 3389);
    await expectLater(
      router(atHome: false).connect(withoutAgent),
      throwsA(isA<RemoteDesktopRouteException>()),
    );
    expect(tunnelAttempts, isEmpty);
  });

  test('sin clave guardada no intenta el túnel', () async {
    keyStore.keys.clear();
    await expectLater(
      router(atHome: false).connect(pc),
      throwsA(isA<RemoteDesktopRouteException>()),
    );
    expect(tunnelAttempts, isEmpty);
  });
}
