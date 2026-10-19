import 'dart:io';

import 'package:altair_agent_protocol/altair_agent_protocol.dart';
import 'package:altair_wake_agent/altair_wake_agent.dart';

const String _usage = '''
Uso: altair_wake_agent --key-file <ruta> [--port <n>] [--rdp-port <n>] [--log-file <ruta>]

  --key-file  Archivo con la clave compartida (base64url, 43 caracteres).
  --port      Puerto TCP de escucha (por defecto $defaultAgentPort).
  --rdp-port  Puerto local del Escritorio remoto para el túnel (por defecto
              $defaultRemoteDesktopPort).
  --log-file  Archivo de registro (opcional).
''';

Future<void> main(List<String> arguments) async {
  final options = _parseOptions(arguments);
  final keyPath = options['key-file'];
  final port = int.tryParse(options['port'] ?? '$defaultAgentPort');
  final rdpPort = int.tryParse(options['rdp-port'] ?? '$defaultRemoteDesktopPort');
  bool valid(int? value) => value != null && value >= 1 && value <= 65535;
  if (keyPath == null || !valid(port) || !valid(rdpPort)) {
    stderr.write(_usage);
    exitCode = 64;
    return;
  }

  final logPath = options['log-file'];
  final logger = AgentLogger(logPath == null ? null : File(logPath));
  final AgentKey key;
  try {
    key = AgentKey.parse(File(keyPath).readAsStringSync());
  } on FileSystemException catch (error) {
    logger.info('No se pudo leer la clave: ${error.message}');
    exitCode = 66;
    return;
  } on FormatException catch (error) {
    logger.info('Clave inválida: ${error.message}');
    exitCode = 65;
    return;
  }

  final server = AgentServer(
    handler: RequestHandler(
      key: key,
      actions: WindowsPowerActions(),
      remoteDesktop: localRemoteDesktop(rdpPort!),
    ),
    logger: logger,
    port: port!,
  );
  try {
    await server.start();
  } on SocketException catch (error) {
    logger.info('No se pudo abrir el puerto $port: ${error.message}');
    exitCode = 69;
  }
}

Map<String, String> _parseOptions(List<String> arguments) {
  final options = <String, String>{};
  for (var i = 0; i + 1 < arguments.length; i += 2) {
    final name = arguments[i];
    if (!name.startsWith('--')) break;
    options[name.substring(2)] = arguments[i + 1];
  }
  return options;
}
