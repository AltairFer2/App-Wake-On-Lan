import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:altair_agent_protocol/altair_agent_protocol.dart';

enum RdpTunnelFailure {
  /// Sin conexión con el agente en esa dirección: se puede probar otra.
  unreachable,

  /// El agente cerró sin responder: la clave no coincide.
  unauthorized,

  /// El agente respondió (o algo respondió) pero no abrió el túnel.
  rejected,
}

class RdpTunnelException implements Exception {
  const RdpTunnelException(this.failure, this.message);

  final RdpTunnelFailure failure;
  final String message;

  @override
  String toString() => 'RdpTunnelException(${failure.name}): $message';
}

/// Conexión autenticada con el agente, lista para llevar el tráfico RDP
/// (ver `tunnel.dart` del protocolo).
class AgentTunnelConnection {
  AgentTunnelConnection._(this._socket, this._fromAgent, this._keys);

  final Socket _socket;
  final Stream<List<int>> _fromAgent;
  final TunnelKeys _keys;

  /// Pide el túnel al agente. Lanza [RdpTunnelException].
  static Future<AgentTunnelConnection> connect(
    InternetAddress address,
    int port,
    AgentKey key, {
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final Socket socket;
    try {
      socket = await Socket.connect(address, port, timeout: timeout);
    } on SocketException catch (error) {
      throw RdpTunnelException(
        RdpTunnelFailure.unreachable,
        'Sin conexión con el agente en ${address.address}:$port (${error.message}).',
      );
    }
    try {
      final request = AgentRequest.create(AgentCommand.remoteDesktop, DateTime.now());
      socket.write('${request.encode(key)}\n');
      await socket.flush();
      final first = await readFirstLine(socket, timeout: timeout);
      _checkResponse(first.line, key, request);
      return AgentTunnelConnection._(socket, first.rest, TunnelKeys.derive(key, request.nonce));
    } on RdpTunnelException {
      socket.destroy();
      rethrow;
    } on SocketException catch (error) {
      socket.destroy();
      throw RdpTunnelException(
        RdpTunnelFailure.rejected,
        'Se perdió la conexión con el agente (${error.message}).',
      );
    }
  }

  static void _checkResponse(String? line, AgentKey key, AgentRequest request) {
    if (line == null || line.trim().isEmpty) {
      throw const RdpTunnelException(
        RdpTunnelFailure.unauthorized,
        'El agente no respondió: la clave no coincide o el agente es '
        'anterior al escritorio remoto fuera de casa (reinstálalo).',
      );
    }
    final AgentResponse response;
    try {
      response = AgentResponse.decodeAndVerify(line.trim(), key, expectedNonce: request.nonce);
    } on AgentProtocolException {
      throw const RdpTunnelException(
        RdpTunnelFailure.rejected,
        'La respuesta no está firmada con la clave del agente.',
      );
    }
    if (response.ok && response.result == tunnelResult) return;
    throw RdpTunnelException(
      RdpTunnelFailure.rejected,
      switch (response.error) {
        AgentErrorCode.clockSkew =>
          'La hora del teléfono y la del PC difieren más de ${maxClockSkew.inSeconds} s.',
        AgentErrorCode.failed =>
          'El PC no pudo abrir el escritorio remoto: puede estar desactivado '
              'o con otra sesión remota abierta.',
        AgentErrorCode.badRequest =>
          'El agente no reconoce la orden: actualízalo en el PC (install.ps1).',
        _ => 'El agente rechazó el escritorio remoto.',
      },
    );
  }

  /// Pasa los datos entre [local] (FreeRDP) y el agente hasta que alguno
  /// cierre o llegue una trama inválida. Siempre cierra ambos.
  Future<void> relay(Socket local) async {
    try {
      await Future.wait([
        _socket
            .addStream(encodeTunnelFrames(local, _keys.appToAgent))
            .then((_) => _socket.close()),
        local
            .addStream(decodeTunnelFrames(_fromAgent, _keys.agentToApp))
            .then((_) => local.close()),
      ], eagerError: true);
    } on TunnelIntegrityException {
      // Trama alterada: se corta la sesión; FreeRDP informa la desconexión.
    } on SocketException {
      // Red caída o FreeRDP cerró: mismo resultado, sesión terminada.
    } finally {
      local.destroy();
      destroy();
    }
  }

  void destroy() => _socket.destroy();
}

/// Puerto local estable por equipo: FreeRDP recuerda el certificado por
/// host y puerto, así que uno fijo evita preguntarlo en cada conexión.
int tunnelLocalPortFor(String deviceId) {
  const base = 40000;
  const span = 10000;
  var hash = 0x811C9DC5; // FNV-1a de 32 bits.
  for (final unit in deviceId.codeUnits) {
    hash = ((hash ^ unit) * 0x01000193) & 0xFFFFFFFF;
  }
  return base + hash % span;
}

/// Túnel en marcha: FreeRDP se conecta a `127.0.0.1:[localPort]`. Corre en
/// un isolate propio para que el tráfico no compita con la interfaz.
class RdpTunnel {
  RdpTunnel._(this.localPort, this._isolate, this._control, this._exit);

  final int localPort;
  final Isolate _isolate;
  final SendPort _control;
  final ReceivePort _exit;

  /// Termina cuando el túnel se cierra por cualquier motivo.
  late final Future<void> done = _exit.first;

  /// Conecta con el agente y abre el puerto local. Lanza
  /// [RdpTunnelException] si el agente no abre el túnel.
  static Future<RdpTunnel> open({
    required InternetAddress agent,
    required int agentPort,
    required AgentKey key,
    int preferredLocalPort = 0,
  }) async {
    final events = ReceivePort();
    final exit = ReceivePort();
    final isolate = await Isolate.spawn(
      _runTunnel,
      _TunnelConfig(events.sendPort, agent.address, agentPort, key, preferredLocalPort),
      onExit: exit.sendPort,
      debugName: 'rdp-tunnel',
    );
    final message = await events.first as List<Object?>;
    events.close();
    if (message.first == 'ready') {
      return RdpTunnel._(message[1]! as int, isolate, message[2]! as SendPort, exit);
    }
    exit.close();
    throw RdpTunnelException(
      RdpTunnelFailure.values.byName(message[1]! as String),
      message[2]! as String,
    );
  }

  /// Cierra el túnel y espera a que termine (como mucho 2 s).
  Future<void> close() async {
    _control.send(null);
    await done.timeout(
      const Duration(seconds: 2),
      onTimeout: () => _isolate.kill(priority: Isolate.immediate),
    );
    _exit.close();
  }
}

class _TunnelConfig {
  const _TunnelConfig(this.events, this.agent, this.port, this.key, this.preferredLocalPort);

  final SendPort events;
  final String agent;
  final int port;
  final AgentKey key;
  final int preferredLocalPort;
}

Future<void> _runTunnel(_TunnelConfig config) async {
  final AgentTunnelConnection connection;
  try {
    connection = await AgentTunnelConnection.connect(
      InternetAddress(config.agent),
      config.port,
      config.key,
    );
  } on RdpTunnelException catch (error) {
    config.events.send(['error', error.failure.name, error.message]);
    return;
  }
  final server = await _bindLocal(config.preferredLocalPort);
  final control = ReceivePort();
  Socket? local;
  control.listen((_) {
    local?.destroy();
    connection.destroy();
    unawaited(server.close());
  });
  config.events.send(['ready', server.port, control.sendPort]);
  try {
    // Solo la primera conexión (FreeRDP); después se deja de escuchar.
    local = await server.first;
    await server.close();
    await connection.relay(local);
  } on StateError {
    // Se cerró antes de que FreeRDP conectara.
    connection.destroy();
  } finally {
    control.close();
  }
}

Future<ServerSocket> _bindLocal(int preferredPort) async {
  if (preferredPort > 0) {
    try {
      return await ServerSocket.bind(InternetAddress.loopbackIPv4, preferredPort);
    } on SocketException {
      // Ocupado: cualquier puerto libre sirve (FreeRDP volverá a preguntar
      // por el certificado).
    }
  }
  return ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
}
