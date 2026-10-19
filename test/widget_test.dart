import 'package:altair_wake/app/app.dart';
import 'package:altair_wake/app/dependencies.dart';
import 'package:altair_wake/core/network/local_network_inspector.dart';
import 'package:altair_wake/core/network/reachability_probe.dart';
import 'package:altair_agent_protocol/altair_agent_protocol.dart';
import 'package:altair_wake/features/devices/domain/device.dart';
import 'package:altair_wake/features/power_control/data/agent_client.dart';
import 'package:altair_wake/features/power_control/domain/power_control_service.dart';
import 'package:altair_wake/features/remote_desktop/data/rdp_client.dart';
import 'package:altair_wake/features/remote_desktop/data/remote_desktop_launcher.dart';
import 'package:altair_wake/features/wake_on_lan/domain/wake_confirmer.dart';
import 'package:altair_wake/features/wake_on_lan/domain/wake_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

AppDependencies buildDependencies(
  InMemoryDeviceRepository repository, [
  InMemoryAgentKeyStore? keyStore,
  ReachabilityStatus probeStatus = ReachabilityStatus.unverifiable,
  PowerControlService? powerControl,
  RemoteDesktopLauncher? remoteDesktop,
  RdpClient? rdpClient,
]) {
  final resolver = FakeAddressResolver();
  final keys = keyStore ?? InMemoryAgentKeyStore();
  return AppDependencies(
    repository: repository,
    wakeService: WakeService(
      sender: FakeUdpSender(),
      resolver: resolver,
      repetitionGap: Duration.zero,
    ),
    confirmer: WakeConfirmer(
      probe: FakeReachabilityProbe(probeStatus),
      timeout: Duration.zero,
      interval: Duration.zero,
    ),
    resolver: resolver,
    networkInspector: FakeNetworkInspector(const LocalNetworkSnapshot([])),
    agentKeyStore: keys,
    powerControl:
        powerControl ??
        PowerControlService(client: const AgentClient(), keyStore: keys),
    remoteDesktop: remoteDesktop ?? FakeRemoteDesktopLauncher(),
    rdpClient: rdpClient ?? FakeRdpClient(supported: false),
  );
}

void main() {
  testWidgets('sin equipos muestra el estado vacío', (tester) async {
    await tester.pumpWidget(
      AltairWakeApp(dependencies: buildDependencies(InMemoryDeviceRepository())),
    );
    await tester.pumpAndSettle();

    expect(find.text('Sin equipos registrados'), findsOneWidget);
  });

  testWidgets('la barra superior muestra el nombre y el logotipo', (tester) async {
    await tester.pumpWidget(
      AltairWakeApp(dependencies: buildDependencies(InMemoryDeviceRepository())),
    );
    await tester.pumpAndSettle();

    expect(find.text('Lazy Wake Up'), findsOneWidget);
    expect(find.bySemanticsLabel('Logotipo de Lazy Wake Up'), findsOneWidget);
  });

  testWidgets('muestra el equipo y su último intento sin inventar estado', (tester) async {
    final repository = InMemoryDeviceRepository([
      sampleDevice(
        lastAttempt: LastWakeAttempt(
          at: DateTime.now(),
          status: WakeAttemptStatus.sent,
        ),
      ),
    ]);
    await tester.pumpWidget(AltairWakeApp(dependencies: buildDependencies(repository)));
    await tester.pumpAndSettle();

    expect(find.text('PC Escritorio'), findsOneWidget);
    expect(find.textContaining('Paquete enviado (sin confirmar)'), findsOneWidget);
    expect(find.text('Sin respuesta'), findsOneWidget);
    expect(find.text('Encendido'), findsNothing);
    expect(find.widgetWithText(FilledButton, 'Encender'), findsOneWidget);
  });

  group('botones según el estado detectado', () {
    testWidgets('encendido con agente muestra Apagar y Suspender', (tester) async {
      final power = FakePowerControl();
      final repository = InMemoryDeviceRepository([sampleDevice(agentPort: 47123)]);
      await tester.pumpWidget(
        AltairWakeApp(
          dependencies: buildDependencies(
            repository,
            null,
            ReachabilityStatus.reachable,
            power,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Encendido'), findsOneWidget);
      expect(find.text('Encender'), findsNothing);
      expect(find.text('Suspender'), findsOneWidget);

      await tester.tap(find.widgetWithText(FilledButton, 'Apagar'));
      await tester.pumpAndSettle();
      expect(find.text('Apagar equipo'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'Apagar').last);
      await tester.pump();

      expect(power.commands, [AgentCommand.shutdown]);
      expect(find.text('Cancelar apagado'), findsOneWidget);

      await tester.tap(find.text('Cancelar apagado'));
      await tester.pumpAndSettle();
      expect(power.commands, [AgentCommand.shutdown, AgentCommand.cancelShutdown]);
      expect(find.widgetWithText(FilledButton, 'Apagar'), findsOneWidget);
    });

    testWidgets('encendido sin agente no ofrece apagar', (tester) async {
      final repository = InMemoryDeviceRepository([sampleDevice()]);
      await tester.pumpWidget(
        AltairWakeApp(
          dependencies: buildDependencies(
            repository,
            null,
            ReachabilityStatus.reachable,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Apagar'), findsNothing);
      final button = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Encendido'),
      );
      expect(button.onPressed, isNull);
    });

    testWidgets('encendido con escritorio remoto abre el cliente', (tester) async {
      final launcher = FakeRemoteDesktopLauncher(RemoteDesktopLaunch.clientApp);
      final repository = InMemoryDeviceRepository([
        sampleDevice(agentPort: 47123, remoteDesktopPort: 3389),
      ]);
      await tester.pumpWidget(
        AltairWakeApp(
          dependencies: buildDependencies(
            repository,
            null,
            ReachabilityStatus.reachable,
            FakePowerControl(),
            launcher,
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Escritorio'));
      await tester.pump();

      expect(launcher.opened, ['192.168.100.20:3389']);
      expect(find.textContaining('agrégalo con 192.168.100.20.'), findsOneWidget);
    });

    testWidgets('con cliente integrado pide credenciales y abre la sesión', (tester) async {
      final rdp = FakeRdpClient();
      final launcher = FakeRemoteDesktopLauncher();
      final repository = InMemoryDeviceRepository([
        sampleDevice(agentPort: 47123, remoteDesktopPort: 3389),
      ]);
      await tester.pumpWidget(
        AltairWakeApp(
          dependencies: buildDependencies(
            repository,
            null,
            ReachabilityStatus.reachable,
            FakePowerControl(),
            launcher,
            rdp,
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Escritorio'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Usuario de Windows'),
        'usuario',
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Conectar'));
      // "Conectando…" tiene un indicador infinito: pumpAndSettle no termina.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      expect(launcher.opened, isEmpty);
      expect(rdp.connections.single.username, 'usuario');
      expect(rdp.connections.single.password, '');
      expect(find.text('Conectando…'), findsOneWidget);

      await tester.tap(find.byTooltip('Desconectar'));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(rdp.disconnects, 1);
      expect(find.text('Conectando…'), findsNothing);
      expect(find.text('PC Escritorio'), findsOneWidget);
    });

    testWidgets('sin respuesta no ofrece escritorio remoto', (tester) async {
      final repository = InMemoryDeviceRepository([
        sampleDevice(remoteDesktopPort: 3389),
      ]);
      await tester.pumpWidget(
        AltairWakeApp(dependencies: buildDependencies(repository)),
      );
      await tester.pumpAndSettle();

      expect(find.text('Escritorio'), findsNothing);
      expect(find.widgetWithText(FilledButton, 'Encender'), findsOneWidget);
    });
  });

  testWidgets('el botón Encender envía y reporta la ruta LAN', (tester) async {
    final repository = InMemoryDeviceRepository([sampleDevice(probePort: null)]);
    await tester.pumpWidget(AltairWakeApp(dependencies: buildDependencies(repository)));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(FilledButton, 'Encender'));
    await tester.pumpAndSettle();

    expect(find.textContaining('LAN 192.168.100.255:9: Paquete UDP enviado'), findsOneWidget);
    expect(repository.stored.single.lastAttempt!.status, WakeAttemptStatus.sent);
  });

  testWidgets('el formulario valida la MAC y crea el equipo', (tester) async {
    final repository = InMemoryDeviceRepository();
    await tester.pumpWidget(AltairWakeApp(dependencies: buildDependencies(repository)));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(FilledButton, 'Agregar equipo'));
    await tester.pumpAndSettle();

    await tester.enterText(find.widgetWithText(TextFormField, 'Nombre'), 'Torre');
    await tester.enterText(find.widgetWithText(TextFormField, 'Dirección MAC'), 'xx');
    await tester.tap(find.widgetWithText(TextButton, 'Guardar'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Formato de MAC no válido'), findsOneWidget);

    await tester.enterText(
      find.widgetWithText(TextFormField, 'Dirección MAC'),
      'd8-bb-c1-0a-ff-01',
    );
    await tester.tap(find.widgetWithText(TextButton, 'Guardar'));
    await tester.pumpAndSettle();

    expect(repository.stored.single.name, 'Torre');
    expect(repository.stored.single.mac.toString(), 'D8:BB:C1:0A:FF:01');
    expect(find.text('Torre'), findsOneWidget);
  });

  testWidgets('el agente exige clave y la guarda fuera del JSON', (tester) async {
    final repository = InMemoryDeviceRepository();
    final keys = InMemoryAgentKeyStore();
    await tester.pumpWidget(
      AltairWakeApp(dependencies: buildDependencies(repository, keys)),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Agregar equipo'));
    await tester.pumpAndSettle();

    await tester.enterText(find.widgetWithText(TextFormField, 'Nombre'), 'PC');
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Dirección MAC'),
      'D8:BB:C1:0A:FF:01',
    );
    final portField = find.widgetWithText(TextFormField, 'Puerto TCP del agente');
    await tester.ensureVisible(portField);
    await tester.enterText(portField, '47123');
    await tester.tap(find.widgetWithText(TextButton, 'Guardar'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Pega la clave'), findsOneWidget);

    final key = AgentKey.generate();
    final keyField = find.widgetWithText(TextFormField, 'Clave del agente');
    await tester.ensureVisible(keyField);
    await tester.enterText(keyField, key.encode());
    await tester.tap(find.widgetWithText(TextButton, 'Guardar'));
    await tester.pumpAndSettle();

    final saved = repository.stored.single;
    expect(saved.agentPort, 47123);
    expect(keys.keys[saved.id]!.encode(), key.encode());
    expect(saved.toJson().toString(), isNot(contains(key.encode())));
  });

  testWidgets('el menú muestra órdenes de energía solo con agente', (tester) async {
    final repository = InMemoryDeviceRepository([
      sampleDevice(probePort: null, agentPort: 47123),
      sampleDevice(id: 'pc-2', name: 'Sin agente', probePort: null),
    ]);
    await tester.pumpWidget(AltairWakeApp(dependencies: buildDependencies(repository)));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Opciones de PC Escritorio'));
    await tester.pumpAndSettle();
    expect(find.text('Apagar'), findsOneWidget);
    expect(find.text('Suspender'), findsOneWidget);
    await tester.tapAt(Offset.zero);
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Opciones de Sin agente'));
    await tester.pumpAndSettle();
    expect(find.text('Apagar'), findsNothing);
  });
}
