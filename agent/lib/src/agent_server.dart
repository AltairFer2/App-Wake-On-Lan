import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:altair_agent_protocol/altair_agent_protocol.dart';

import 'agent_logger.dart';
import 'request_handler.dart';

/// Servidor TCP: una petición por conexión, terminada en salto de línea.
class AgentServer {
  AgentServer({
    required this._handler,
    required this._logger,
    this.port = defaultAgentPort,
    this.readTimeout = const Duration(seconds: 5),
    this.actionDelay = const Duration(seconds: 2),
  });

  final RequestHandler _handler;
  final AgentLogger _logger;
  final int port;
  final Duration readTimeout;

  /// Espera antes de suspender, para que la respuesta llegue al teléfono.
  final Duration actionDelay;

  ServerSocket? _server;

  int get boundPort => _server?.port ?? port;

  /// Escucha en IPv4 e IPv6. El firewall de Windows restringe el origen a la
  /// subred local.
  Future<void> start() async {
    _server = await ServerSocket.bind(InternetAddress.anyIPv6, port, v6Only: false);
    _server!.listen(_handleConnection);
    _logger.info('Agente escuchando en el puerto $boundPort');
  }

  Future<void> close() async => _server?.close();

  Future<void> _handleConnection(Socket socket) async {
    final source = socket.remoteAddress.address;
    try {
      final line = await _readLine(socket);
      // Las conexiones sin petición son, en su mayoría, sondeos de estado de
      // la app; no se registran para no llenar el registro.
      if (line == null) return;
      final handled = await _handler.handle(line, source);
      _logger.info(handled.logLine);
      final response = handled.response;
      if (response != null) {
        socket.write('$response\n');
        await socket.flush();
      }
      final action = handled.afterResponse;
      if (action != null) {
        unawaited(_runDeferred(action));
      }
    } on SocketException catch (error) {
      _logger.info('$source: error de socket (${error.message})');
    } finally {
      socket.destroy();
    }
  }

  Future<void> _runDeferred(Future<void> Function() action) async {
    await Future<void>.delayed(actionDelay);
    try {
      await action();
    } on Exception catch (error) {
      _logger.info('Error al ejecutar la acción: $error');
    }
  }

  /// Lee hasta el primer salto de línea con límite de tamaño y de tiempo.
  Future<String?> _readLine(Socket socket) async {
    final buffer = BytesBuilder(copy: false);
    final completer = Completer<String?>();
    late final StreamSubscription<List<int>> subscription;
    subscription = socket.listen(
      (chunk) {
        final newline = chunk.indexOf(10);
        buffer.add(newline == -1 ? chunk : chunk.sublist(0, newline));
        if (buffer.length > maxMessageBytes) {
          completer.complete(null);
        } else if (newline != -1) {
          completer.complete(utf8.decode(buffer.takeBytes(), allowMalformed: true));
        }
        if (completer.isCompleted) subscription.pause();
      },
      onError: (Object _) {
        if (!completer.isCompleted) completer.complete(null);
      },
      onDone: () {
        if (!completer.isCompleted) completer.complete(null);
      },
      cancelOnError: true,
    );
    try {
      return await completer.future.timeout(readTimeout, onTimeout: () => null);
    } finally {
      await subscription.cancel();
    }
  }
}
