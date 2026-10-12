import 'package:altair_agent_protocol/altair_agent_protocol.dart';
import 'package:altair_wake/core/errors/storage_exception.dart';
import 'package:altair_wake/core/network/reachability_probe.dart';
import 'package:altair_wake/features/devices/domain/device.dart';
import 'package:altair_wake/features/devices/presentation/device_list_controller.dart';
import 'package:altair_wake/features/power_control/data/agent_client.dart';
import 'package:altair_wake/features/wake_on_lan/domain/wake_confirmer.dart';
import 'package:altair_wake/features/wake_on_lan/domain/wake_service.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fakes.dart';

void main() {
  late InMemoryDeviceRepository repository;
  late FakeUdpSender sender;
  late FakeReachabilityProbe probe;
  late FakePowerControl power;

  DeviceListController buildController() => DeviceListController(
    repository: repository,
    wakeService: WakeService(
      sender: sender,
      resolver: FakeAddressResolver(),
      repetitionGap: Duration.zero,
    ),
    confirmer: WakeConfirmer(
      probe: probe,
      timeout: const Duration(milliseconds: 30),
      interval: const Duration(milliseconds: 5),
    ),
    powerControl: power,
  );

  setUp(() {
    repository = InMemoryDeviceRepository([sampleDevice()]);
    sender = FakeUdpSender();
    probe = FakeReachabilityProbe();
    power = FakePowerControl();
  });

  test('carga los dispositivos y sondea su estado', () async {
    probe.status = ReachabilityStatus.reachable;
    final controller = buildController();
    addTearDown(controller.dispose);
    await controller.load();
    await controller.refreshConnectivity();
    expect(controller.loadState, LoadState.ready);
    expect(controller.devices.single.name, 'PC Escritorio');
    expect(controller.runtimeOf('pc-1').connectivity, ReachabilityStatus.reachable);
  });

  test('paquete enviado sin respuesta queda como "no confirmado"', () async {
    final controller = buildController();
    addTearDown(controller.dispose);
    await controller.load();

    await controller.wake(controller.devices.single);

    expect(sender.sent, isNotEmpty);
    final saved = repository.stored.single.lastAttempt!;
    expect(saved.status, WakeAttemptStatus.notConfirmed);
    final runtime = controller.runtimeOf('pc-1');
    expect(runtime.phase, DevicePhase.idle);
    expect(runtime.connectivity, ReachabilityStatus.unverifiable);
  });

  test('confirma el encendido solo cuando el sondeo responde', () async {
    probe.status = ReachabilityStatus.reachable;
    final controller = buildController();
    addTearDown(controller.dispose);
    await controller.load();

    await controller.wake(controller.devices.single);

    expect(
      repository.stored.single.lastAttempt!.status,
      WakeAttemptStatus.confirmedAwake,
    );
  });

  test('si ya respondía, el envío no se registra como encendido confirmado', () async {
    probe.status = ReachabilityStatus.reachable;
    final controller = buildController();
    addTearDown(controller.dispose);
    await controller.load();
    await controller.refreshConnectivity();

    await controller.wake(controller.devices.single);

    expect(sender.sent, isNotEmpty);
    expect(repository.stored.single.lastAttempt!.status, WakeAttemptStatus.sent);
    expect(controller.runtimeOf('pc-1').phase, DevicePhase.idle);
  });

  test('sin sondeo configurado registra "enviado" sin confirmar', () async {
    repository = InMemoryDeviceRepository([sampleDevice(probePort: null)]);
    final controller = buildController();
    addTearDown(controller.dispose);
    await controller.load();

    await controller.wake(controller.devices.single);

    expect(repository.stored.single.lastAttempt!.status, WakeAttemptStatus.sent);
    expect(probe.calls, 0);
  });

  group('órdenes de energía', () {
    test('tras apagar, sigue el estado hasta que deja de responder', () async {
      probe.status = ReachabilityStatus.reachable;
      final controller = buildController();
      addTearDown(controller.dispose);
      await controller.load();
      await controller.refreshConnectivity();
      final messages = <String>[];
      controller.messages.listen(messages.add);

      final pending = controller.sendPowerCommand(
        controller.devices.single,
        AgentCommand.shutdown,
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(controller.runtimeOf('pc-1').phase, DevicePhase.poweringDown);
      expect(controller.runtimeOf('pc-1').powerCommand, AgentCommand.shutdown);

      probe.status = ReachabilityStatus.unverifiable;
      await pending;
      // El stream de mensajes entrega los avisos en una microtarea posterior.
      await Future<void>.delayed(Duration.zero);

      expect(power.commands, [AgentCommand.shutdown]);
      expect(controller.runtimeOf('pc-1').phase, DevicePhase.idle);
      expect(
        controller.runtimeOf('pc-1').connectivity,
        ReachabilityStatus.unverifiable,
      );
      expect(messages.last, contains('dejó de responder'));
    });

    test('cancelar el apagado detiene el seguimiento', () async {
      probe.status = ReachabilityStatus.reachable;
      final controller = buildController();
      addTearDown(controller.dispose);
      await controller.load();
      final device = controller.devices.single;

      final pending = controller.sendPowerCommand(device, AgentCommand.shutdown);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      await controller.sendPowerCommand(device, AgentCommand.cancelShutdown);
      await pending;

      expect(power.commands, [AgentCommand.shutdown, AgentCommand.cancelShutdown]);
      expect(controller.runtimeOf('pc-1').phase, DevicePhase.idle);
      expect(
        controller.runtimeOf('pc-1').connectivity,
        ReachabilityStatus.reachable,
      );
    });

    test('una orden rechazada no cambia el estado', () async {
      power.outcome = AgentCallOutcome.unauthorized;
      final controller = buildController();
      addTearDown(controller.dispose);
      await controller.load();
      final messages = <String>[];
      controller.messages.listen(messages.add);

      await controller.sendPowerCommand(
        controller.devices.single,
        AgentCommand.shutdown,
      );
      await Future<void>.delayed(Duration.zero);

      expect(controller.runtimeOf('pc-1').phase, DevicePhase.idle);
      expect(messages.single, contains('unauthorized'));
    });

    test('no admite otra orden mientras se enciende', () async {
      final controller = buildController();
      addTearDown(controller.dispose);
      await controller.load();
      final device = controller.devices.single;

      final waking = controller.wake(device);
      await controller.sendPowerCommand(device, AgentCommand.shutdown);
      await waking;

      expect(power.commands, isEmpty);
    });
  });

  test('upsert revierte y propaga el error si no se puede guardar', () async {
    final controller = buildController();
    addTearDown(controller.dispose);
    await controller.load();
    repository.failOnSave = true;

    await expectLater(
      controller.upsert(sampleDevice(id: 'pc-2', name: 'Otra')),
      throwsA(isA<StorageException>()),
    );
    expect(controller.devices, hasLength(1));
  });

  test('delete elimina y persiste', () async {
    final controller = buildController();
    addTearDown(controller.dispose);
    await controller.load();

    await controller.delete('pc-1');

    expect(controller.devices, isEmpty);
    expect(repository.stored, isEmpty);
  });
}
