import 'dart:io';

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
}

class WindowsPowerActions implements PowerActions {
  const WindowsPowerActions({this.shutdownGrace = const Duration(seconds: 30)});

  final Duration shutdownGrace;

  @override
  Future<void> scheduleShutdown() => _runShutdownExe([
    '/s',
    '/t',
    '${shutdownGrace.inSeconds}',
    '/d',
    'p:0:0',
    '/c',
    'Apagado solicitado desde Altair Wake. Cancelar: shutdown /a',
  ]);

  @override
  Future<void> cancelShutdown() => _runShutdownExe(['/a']);

  @override
  Future<void> suspend() async => suspendToRam();

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
