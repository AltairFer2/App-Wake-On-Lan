import 'dart:io';

import 'package:altair_agent_protocol/altair_agent_protocol.dart';

import 'windows_display.dart';
import 'windows_suspend.dart';

/// Falla al ejecutar una acción de energía.
class PowerActionException implements Exception {
  const PowerActionException(this.message);

  final String message;

  @override
  String toString() => 'PowerActionException: $message';
}

abstract interface class PowerActions {
  /// Programa el apagado con un margen que permite cancelarlo.
  Future<void> scheduleShutdown();

  Future<void> cancelShutdown();

  /// Suspende a S3. Retorna cuando el equipo despierta.
  Future<void> suspend();

  /// Enciende la pantalla y mantiene el equipo despierto durante un plazo,
  /// para poder conectarse por escritorio remoto tras un despertar por red.
  Future<void> keepDisplayOn();
}

class WindowsPowerActions implements PowerActions {
  WindowsPowerActions({
    this.shutdownGrace = const Duration(seconds: 30),
    this.displayHold = displayHoldDuration,
  });

  final Duration shutdownGrace;

  /// Tiempo para conectarse; después rigen los temporizadores de Windows.
  final Duration displayHold;

  final DisplayKeepAlive _display = DisplayKeepAlive();

  @override
  Future<void> scheduleShutdown() async {
    _display.release();
    await _runShutdownExe([
    '/s',
    '/t',
    '${shutdownGrace.inSeconds}',
    '/d',
    'p:0:0',
    '/c',
    'Apagado solicitado desde Altair Wake. Cancelar: shutdown /a',
    ]);
  }

  @override
  Future<void> cancelShutdown() => _runShutdownExe(['/a']);

  @override
  Future<void> suspend() async {
    _display.release();
    suspendToRam();
  }

  @override
  Future<void> keepDisplayOn() async => _display.hold(displayHold);

  Future<void> _runShutdownExe(List<String> arguments) async {
    final result = await Process.run('shutdown.exe', arguments);
    if (result.exitCode != 0) {
      throw PowerActionException(
        'shutdown.exe ${arguments.first} terminó con código ${result.exitCode}: '
        '${result.stderr.toString().trim()}',
      );
    }
  }
}
