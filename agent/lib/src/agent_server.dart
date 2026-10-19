import 'dart:async';
import 'dart:io';

import 'package:altair_agent_protocol/altair_agent_protocol.dart';

import 'agent_logger.dart';
import 'request_handler.dart';

/// Servidor TCP: una petición por conexión, terminada en salto de línea. La
/// orden de escritorio remoto convierte después la conexión en un túnel.
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
      final first = await readFirstLine(socket, timeout: readTimeout);
      final line = first.line;
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
      final tunnel = handled.tunnel;
      if (tunnel != null) {
        await _relay(socket, first.rest, tunnel, source);
        return;
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

  /// Pasa los datos entre el teléfono (tramas autenticadas) y el Escritorio
  /// remoto hasta que cualquiera de los dos cierre o llegue una trama
  /// inválida.
  Future<void> _relay(
    Socket phone,
    Stream<List<int>> fromPhone,
    AgentTunnel tunnel,
    String source,
  ) async {
    final remoteDesktop = tunnel.remoteDesktop;
    var reason = 'cerrado';
    try {
      await Future.wait([
        remoteDesktop
            .addStream(decodeTunnelFrames(fromPhone, tunnel.keys.appToAgent))
            .then((_) => remoteDesktop.close()),
        phone
            .addStream(encodeTunnelFrames(remoteDesktop, tunnel.keys.agentToApp))
            .then((_) => phone.close()),
      ], eagerError: true);
    } on TunnelIntegrityException catch (error) {
      reason = 'trama rechazada (${error.message})';
    } on SocketException catch (error) {
      reason = 'error de socket (${error.message})';
    } finally {
      remoteDesktop.destroy();
      tunnel.release();
      _logger.info('$source rdp: túnel $reason');
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
}
