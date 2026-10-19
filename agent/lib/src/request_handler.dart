import 'dart:io';

import 'package:altair_agent_protocol/altair_agent_protocol.dart';

import 'failure_rate_limiter.dart';
import 'power_actions.dart';

/// Abre la conexión con el Escritorio remoto del propio PC.
typedef RemoteDesktopConnector = Future<Socket> Function();

/// Puerto del Escritorio remoto de Windows en el propio PC.
const int defaultRemoteDesktopPort = 3389;

/// Conexión por el bucle local: no pasa por el firewall ni requiere que RDP
/// acepte conexiones de fuera de la subred.
RemoteDesktopConnector localRemoteDesktop([int port = defaultRemoteDesktopPort]) =>
    () => Socket.connect(
      InternetAddress.loopbackIPv4,
      port,
      timeout: const Duration(seconds: 5),
    );

/// Túnel autorizado: conexión RDP ya abierta y claves de la sesión.
class AgentTunnel {
  AgentTunnel(this.remoteDesktop, this.keys, this._release);

  final Socket remoteDesktop;
  final TunnelKeys keys;
  final void Function() _release;
  bool _released = false;

  /// Libera el cupo de túneles. Idempotente.
  void release() {
    if (_released) return;
    _released = true;
    _release();
  }
}

/// Resultado de procesar una línea: respuesta a enviar y, para la
/// suspensión, una acción diferida que debe ejecutarse después de responder.
class HandledRequest {
  const HandledRequest({
    this.response,
    this.afterResponse,
    this.tunnel,
    required this.logLine,
  });

  /// `null` si no debe responderse (origen bloqueado o petición sin firma
  /// válida): se cierra la conexión sin datos.
  final String? response;
  final Future<void> Function()? afterResponse;

  /// Si no es `null`, la conexión sigue como túnel tras la respuesta.
  final AgentTunnel? tunnel;
  final String logLine;
}

class RequestHandler {
  RequestHandler({
    required this._key,
    required this._actions,
    RemoteDesktopConnector? remoteDesktop,
    FailureRateLimiter? rateLimiter,
    ReplayGuard? replayGuard,
    DateTime Function()? clock,
  }) : _remoteDesktop = remoteDesktop ?? localRemoteDesktop(),
       _rateLimiter = rateLimiter ?? FailureRateLimiter(),
       _replayGuard = replayGuard ?? ReplayGuard(),
       _clock = clock ?? DateTime.now;

  final AgentKey _key;
  final PowerActions _actions;
  final RemoteDesktopConnector _remoteDesktop;

  /// Sesiones de escritorio remoto simultáneas permitidas.
  static const int maxTunnels = 2;
  int _activeTunnels = 0;
  int get activeTunnels => _activeTunnels;
  final FailureRateLimiter _rateLimiter;
  final ReplayGuard _replayGuard;
  final DateTime Function() _clock;

  Future<HandledRequest> handle(String line, String source) async {
    final now = _clock();
    if (_rateLimiter.isBlocked(source, now)) {
      return HandledRequest(logLine: '$source bloqueado: petición ignorada');
    }
    final AgentRequest request;
    try {
      request = AgentRequest.decodeAndVerify(
        line,
        _key,
        now: now,
        replayGuard: _replayGuard,
      );
    } on AgentProtocolException catch (error) {
      _rateLimiter.recordFailure(source, now);
      // A quien no demuestra tener la clave no se le responde nada (ni la
      // hora del agente). Con firma válida se informa el motivo, firmado.
      final authenticated =
          error.code == AgentErrorCode.clockSkew ||
          error.code == AgentErrorCode.replay;
      return HandledRequest(
        response: authenticated
            ? _respond(_nonceOf(line), ok: false, error: error.code)
            : null,
        logLine: '$source rechazado: ${error.code.wireName}',
      );
    }
    final command = request.command.wireName;
    switch (request.command) {
      case AgentCommand.status:
        return HandledRequest(
          response: _respond(request.nonce, ok: true, result: 'awake'),
          logLine: '$source $command: awake',
        );
      case AgentCommand.suspend:
        return HandledRequest(
          response: _respond(request.nonce, ok: true, result: 'accepted'),
          afterResponse: _actions.suspend,
          logLine: '$source $command: aceptado',
        );
      case AgentCommand.shutdown:
        return _runNow(request, source, _actions.scheduleShutdown);
      case AgentCommand.cancelShutdown:
        return _runNow(request, source, _actions.cancelShutdown);
      case AgentCommand.wakeDisplay:
        return _runNow(request, source, _actions.keepDisplayOn);
      case AgentCommand.remoteDesktop:
        return _openTunnel(request, source);
    }
  }

  Future<HandledRequest> _openTunnel(AgentRequest request, String source) async {
    final command = request.command.wireName;
    if (_activeTunnels >= maxTunnels) {
      return HandledRequest(
        response: _respond(request.nonce, ok: false, error: AgentErrorCode.failed),
        logLine: '$source $command: rechazado, ya hay $_activeTunnels túneles',
      );
    }
    final Socket connection;
    try {
      connection = await _remoteDesktop();
    } on SocketException catch (error) {
      return HandledRequest(
        response: _respond(request.nonce, ok: false, error: AgentErrorCode.failed),
        logLine: '$source $command: escritorio remoto no disponible (${error.message})',
      );
    }
    _activeTunnels++;
    return HandledRequest(
      response: _respond(request.nonce, ok: true, result: tunnelResult),
      tunnel: AgentTunnel(
        connection,
        TunnelKeys.derive(_key, request.nonce),
        () => _activeTunnels--,
      ),
      logLine: '$source $command: túnel abierto',
    );
  }

  Future<HandledRequest> _runNow(
    AgentRequest request,
    String source,
    Future<void> Function() action,
  ) async {
    final command = request.command.wireName;
    try {
      await action();
      return HandledRequest(
        response: _respond(request.nonce, ok: true, result: 'accepted'),
        logLine: '$source $command: ejecutado',
      );
    } on PowerActionException catch (error) {
      return HandledRequest(
        response: _respond(request.nonce, ok: false, error: AgentErrorCode.failed),
        logLine: '$source $command: error (${error.message})',
      );
    }
  }

  String _respond(
    String nonce, {
    required bool ok,
    String? result,
    AgentErrorCode? error,
  }) => AgentResponse(
    requestNonce: nonce,
    ok: ok,
    agentTime: _clock(),
    result: result,
    error: error,
  ).encode(_key);

  static final RegExp _nonceField = RegExp(r'"nonce"\s*:\s*"([0-9a-f]{32})"');

  static String _nonceOf(String line) =>
      _nonceField.firstMatch(line)?.group(1) ?? '';
}
