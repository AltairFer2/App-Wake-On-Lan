import 'dart:async';

import 'package:altair_agent_protocol/altair_agent_protocol.dart';
import 'package:flutter/foundation.dart';

import '../../../core/errors/storage_exception.dart';
import '../../../core/network/reachability_probe.dart';
import '../../power_control/domain/power_control_service.dart';
import '../../wake_on_lan/domain/wake_confirmer.dart';
import '../../wake_on_lan/domain/wake_report.dart';
import '../../wake_on_lan/domain/wake_service.dart';
import '../data/device_repository.dart';
import '../domain/device.dart';

enum LoadState { loading, ready, failed }

/// Operación en curso sobre un dispositivo.
enum DevicePhase {
  idle,

  /// Enviando el paquete mágico.
  sending,

  /// Paquete enviado; esperando que el equipo responda.
  confirming,

  /// Orden de apagado o suspensión aceptada; esperando que deje de responder.
  poweringDown,
}

/// Estado efímero (no persistido) de un dispositivo en pantalla.
class DeviceRuntimeState {
  const DeviceRuntimeState({
    this.connectivity,
    this.checking = false,
    this.phase = DevicePhase.idle,
    this.lastReport,
    this.powerCommand,
  });

  /// `null` si no hay sondeo configurado o aún no se ejecutó.
  final ReachabilityStatus? connectivity;
  final bool checking;
  final DevicePhase phase;
  final WakeReport? lastReport;

  /// Orden en curso cuando [phase] es [DevicePhase.poweringDown].
  final AgentCommand? powerCommand;

  DeviceRuntimeState copyWith({
    ReachabilityStatus? connectivity,
    bool? checking,
    DevicePhase? phase,
    WakeReport? lastReport,
    AgentCommand? powerCommand,
  }) => DeviceRuntimeState(
    connectivity: connectivity ?? this.connectivity,
    checking: checking ?? this.checking,
    phase: phase ?? this.phase,
    lastReport: lastReport ?? this.lastReport,
    powerCommand: powerCommand ?? this.powerCommand,
  );
}

class DeviceListController extends ChangeNotifier {
  DeviceListController({
    required this._repository,
    required this._wakeService,
    required this._confirmer,
    required this._powerControl,
  });

  final DeviceRepository _repository;
  final WakeService _wakeService;
  final WakeConfirmer _confirmer;
  final PowerControlService _powerControl;

  final Map<String, DeviceRuntimeState> _runtime = {};
  final Set<String> _cancelledPowerDowns = {};
  final StreamController<String> _messages = StreamController.broadcast();
  List<Device> _devices = const [];
  LoadState _loadState = LoadState.loading;
  String? _loadError;
  bool _disposed = false;

  List<Device> get devices => List.unmodifiable(_devices);
  LoadState get loadState => _loadState;
  String? get loadError => _loadError;

  /// Avisos no bloqueantes para mostrar al usuario.
  Stream<String> get messages => _messages.stream;

  DeviceRuntimeState runtimeOf(String id) =>
      _runtime[id] ?? const DeviceRuntimeState();

  Future<void> load() async {
    _loadState = LoadState.loading;
    _loadError = null;
    _notify();
    try {
      _devices = await _repository.loadAll();
      _loadState = LoadState.ready;
    } on StorageException catch (error) {
      _loadError = error.message;
      _loadState = LoadState.failed;
      debugPrint('Fallo al cargar dispositivos: $error');
    }
    _notify();
    if (_loadState == LoadState.ready) unawaited(refreshConnectivity());
  }

  /// Agrega o reemplaza un dispositivo. Lanza [StorageException] y revierte
  /// el cambio en memoria si no se pudo guardar.
  Future<void> upsert(Device device) async {
    final previous = _devices;
    final index = _devices.indexWhere((d) => d.id == device.id);
    _devices = [..._devices];
    if (index == -1) {
      _devices.add(device);
    } else {
      _devices[index] = device;
    }
    await _persistOrRevert(previous);
    _notify();
    unawaited(_refreshOne(device));
  }

  Future<void> delete(String id) async {
    final previous = _devices;
    _devices = _devices.where((d) => d.id != id).toList();
    await _persistOrRevert(previous);
    _runtime.remove(id);
    _notify();
  }

  /// Sondea los equipos sin operación en curso. Seguro para llamarse
  /// periódicamente: omite los que ya se están comprobando.
  Future<void> refreshConnectivity() async {
    await Future.wait([
      for (final device in _devices)
        if (runtimeOf(device.id).phase == DevicePhase.idle &&
            !runtimeOf(device.id).checking)
          _refreshOne(device),
    ]);
  }

  /// Envía el paquete mágico y, si hay sondeo configurado, espera la
  /// confirmación. Nunca marca "encendido" sin una respuesta del equipo.
  Future<void> wake(Device device) async {
    if (runtimeOf(device.id).phase != DevicePhase.idle) return;
    _setPhase(device.id, DevicePhase.sending);
    try {
      await _wakeAndConfirm(device);
    } on Object catch (error, stackTrace) {
      // Errores no previstos por WakeService: se registran con su traza y se
      // libera la tarjeta para permitir un nuevo intento.
      debugPrint('Error inesperado al encender: $error\n$stackTrace');
      _message('Error inesperado al enviar el paquete.');
      if (_exists(device.id)) _setPhase(device.id, DevicePhase.idle);
    }
  }

  /// Envía una orden al agente. Tras aceptar un apagado o una suspensión,
  /// sigue el estado hasta que el equipo deja de responder.
  Future<void> sendPowerCommand(Device device, AgentCommand command) async {
    final phase = runtimeOf(device.id).phase;
    final isCancel = command == AgentCommand.cancelShutdown;
    if (phase != DevicePhase.idle && !(isCancel && phase == DevicePhase.poweringDown)) {
      return;
    }
    try {
      final result = await _powerControl.run(device, command);
      if (!_exists(device.id)) return;
      if (!result.isAccepted) {
        _message(result.message);
        return;
      }
      switch (command) {
        case AgentCommand.status:
          _setRuntime(
            device.id,
            runtimeOf(device.id).copyWith(connectivity: ReachabilityStatus.reachable),
          );
          _message('${device.name} está encendido (agente autenticado).');
        case AgentCommand.cancelShutdown:
          _cancelledPowerDowns.add(device.id);
          _setRuntime(
            device.id,
            runtimeOf(device.id).copyWith(
              phase: DevicePhase.idle,
              connectivity: ReachabilityStatus.reachable,
            ),
          );
          _message('Apagado cancelado.');
        case AgentCommand.suspend:
        case AgentCommand.shutdown:
          await _followPowerDown(device, command);
      }
    } on StorageException catch (error) {
      _message(error.message);
    }
  }

  Future<void> _followPowerDown(Device device, AgentCommand command) async {
    final verb = command == AgentCommand.suspend ? 'suspenderá' : 'apagará';
    _message(
      command == AgentCommand.suspend
          ? '${device.name} se $verb en unos segundos.'
          : '${device.name} se $verb en 30 s.',
    );
    if (probeTargetsFor(device).isEmpty) return;
    _cancelledPowerDowns.remove(device.id);
    _setRuntime(
      device.id,
      runtimeOf(device.id).copyWith(
        phase: DevicePhase.poweringDown,
        powerCommand: command,
      ),
    );
    final stopped = await _confirmer.waitUntilUnresponsive(
      device,
      isCancelled: () =>
          _disposed ||
          !_exists(device.id) ||
          _cancelledPowerDowns.contains(device.id),
    );
    if (_disposed || !_exists(device.id) || _cancelledPowerDowns.remove(device.id)) {
      return;
    }
    _setRuntime(
      device.id,
      runtimeOf(device.id).copyWith(
        phase: DevicePhase.idle,
        connectivity: stopped
            ? ReachabilityStatus.unverifiable
            : ReachabilityStatus.reachable,
      ),
    );
    _message(
      stopped
          ? '${device.name} dejó de responder tras la orden.'
          : '${device.name} sigue respondiendo; revisa el equipo.',
    );
  }

  Future<void> _wakeAndConfirm(Device device) async {
    final wasAwake =
        runtimeOf(device.id).connectivity == ReachabilityStatus.reachable;
    final report = await _wakeService.wake(device);
    await _recordAttempt(device.id, report.at, report.status);
    // Si ya respondía, una respuesta posterior no demuestra que el paquete
    // lo encendiera: no se registra como encendido confirmado.
    if (wasAwake) {
      _setRuntime(
        device.id,
        runtimeOf(device.id).copyWith(lastReport: report, phase: DevicePhase.idle),
      );
      _message(
        '${device.name} ya estaba encendido; el paquete se envió, pero esto '
        'no confirma que Wake-on-LAN funcione.',
      );
      return;
    }
    final canConfirm = report.anySent && probeTargetsFor(device).isNotEmpty;
    _setRuntime(
      device.id,
      runtimeOf(device.id).copyWith(
        lastReport: report,
        phase: canConfirm ? DevicePhase.confirming : DevicePhase.idle,
      ),
    );
    if (!canConfirm) return;

    final confirmed = await _confirmer.waitUntilReachable(
      device,
      isCancelled: () => _disposed || !_exists(device.id),
    );
    if (_disposed || !_exists(device.id)) return;
    await _recordAttempt(
      device.id,
      report.at,
      confirmed
          ? WakeAttemptStatus.confirmedAwake
          : WakeAttemptStatus.notConfirmed,
    );
    _setRuntime(
      device.id,
      runtimeOf(device.id).copyWith(
        phase: DevicePhase.idle,
        connectivity: confirmed
            ? ReachabilityStatus.reachable
            : ReachabilityStatus.unverifiable,
      ),
    );
  }

  Future<void> _refreshOne(Device device) async {
    if (probeTargetsFor(device).isEmpty) {
      _runtime[device.id] = DeviceRuntimeState(
        phase: runtimeOf(device.id).phase,
        lastReport: runtimeOf(device.id).lastReport,
      );
      _notify();
      return;
    }
    _setRuntime(device.id, runtimeOf(device.id).copyWith(checking: true));
    final status = await _confirmer.checkOnce(device);
    if (_disposed || !_exists(device.id)) return;
    final current = runtimeOf(device.id);
    // Si mientras tanto empezó una operación, ella es dueña del estado.
    _setRuntime(
      device.id,
      current.phase == DevicePhase.idle
          ? current.copyWith(connectivity: status, checking: false)
          : current.copyWith(checking: false),
    );
  }

  Future<void> _recordAttempt(
    String id,
    DateTime at,
    WakeAttemptStatus status,
  ) async {
    final index = _devices.indexWhere((d) => d.id == id);
    if (index == -1) return;
    _devices = [..._devices]
      ..[index] = _devices[index].withLastAttempt(
        LastWakeAttempt(at: at, status: status),
      );
    _notify();
    try {
      await _repository.saveAll(_devices);
    } on StorageException catch (error) {
      debugPrint('Fallo al guardar el intento: $error');
      _message('No se pudo guardar el resultado del intento.');
    }
  }

  Future<void> _persistOrRevert(List<Device> previous) async {
    try {
      await _repository.saveAll(_devices);
    } on StorageException {
      _devices = previous;
      _notify();
      rethrow;
    }
  }

  bool _exists(String id) => _devices.any((d) => d.id == id);

  void _setPhase(String id, DevicePhase phase) =>
      _setRuntime(id, runtimeOf(id).copyWith(phase: phase));

  void _setRuntime(String id, DeviceRuntimeState state) {
    _runtime[id] = state;
    _notify();
  }

  void _message(String text) {
    if (!_disposed) _messages.add(text);
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _messages.close();
    super.dispose();
  }
}
