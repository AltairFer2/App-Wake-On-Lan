import 'dart:io';

import 'package:altair_agent_protocol/altair_agent_protocol.dart';

import '../../../core/security/agent_key_store.dart';
import '../../devices/domain/device.dart';
import '../../power_control/domain/power_control_service.dart';
import '../data/rdp_tunnel.dart';
import 'remote_desktop.dart';

/// Adónde conecta FreeRDP para una sesión.
class RemoteDesktopEndpoint {
  const RemoteDesktopEndpoint({
    required this.host,
    required this.port,
    this.viaAgent = false,
    this._onClose,
  });

  final String host;
  final int port;

  /// Por el túnel del agente (fuera de casa) en lugar de la red local.
  final bool viaAgent;
  final Future<void> Function()? _onClose;

  /// Libera el túnel, si lo hay. Llamar al terminar la sesión.
  Future<void> close() async => _onClose?.call();
}

/// No hay forma de llegar al escritorio remoto; [message] explica por qué.
class RemoteDesktopRouteException implements Exception {
  const RemoteDesktopRouteException(this.message);

  final String message;

  @override
  String toString() => 'RemoteDesktopRouteException: $message';
}

typedef OpenedTunnel = ({int localPort, Future<void> Function() close});

typedef RdpTunnelOpener =
    Future<OpenedTunnel> Function(
      InternetAddress agent,
      int agentPort,
      AgentKey key,
      int preferredLocalPort,
    );

typedef DirectRdpProbe = Future<bool> Function(String host, int port);

Future<OpenedTunnel> openRdpTunnel(
  InternetAddress agent,
  int agentPort,
  AgentKey key,
  int preferredLocalPort,
) async {
  final tunnel = await RdpTunnel.open(
    agent: agent,
    agentPort: agentPort,
    key: key,
    preferredLocalPort: preferredLocalPort,
  );
  return (localPort: tunnel.localPort, close: tunnel.close);
}

/// En casa RDP contesta enseguida; fuera, la IP local no responde o tarda.
Future<bool> rdpAcceptsConnections(String host, int port) async {
  try {
    final socket = await Socket.connect(
      host,
      port,
      timeout: const Duration(milliseconds: 1500),
    );
    socket.destroy();
    return true;
  } on SocketException {
    return false;
  }
}

/// Elige cómo conectar: directo por la red local si RDP responde; si no, por
/// el túnel del agente (IPv4 local y después IPv6, como las órdenes).
class RemoteDesktopRouter {
  const RemoteDesktopRouter({
    required this._keyStore,
    this._probe = rdpAcceptsConnections,
    this._openTunnel = openRdpTunnel,
  });

  final AgentKeyStore _keyStore;
  final DirectRdpProbe _probe;
  final RdpTunnelOpener _openTunnel;

  /// Lanza [RemoteDesktopRouteException] si no hay ruta, o
  /// `StorageException` si la clave guardada no puede leerse.
  Future<RemoteDesktopEndpoint> connect(Device device) async {
    final port = device.remoteDesktopPort;
    if (port == null) {
      throw const RemoteDesktopRouteException('El equipo no tiene escritorio remoto configurado.');
    }
    final host = remoteDesktopHostOf(device);
    if (host != null && await _probe(host, port)) {
      return RemoteDesktopEndpoint(host: host, port: port);
    }

    final agentPort = device.agentPort;
    final agents = PowerControlService.agentAddressesOf(device);
    if (agentPort == null || agents.isEmpty) {
      throw const RemoteDesktopRouteException(
        'El escritorio remoto no responde en la red local. Fuera de casa '
        'hace falta el agente de Windows configurado en el equipo.',
      );
    }
    final key = await _keyStore.read(device.id);
    if (key == null) {
      throw const RemoteDesktopRouteException('No hay clave del agente guardada para este equipo.');
    }
    for (final agent in agents) {
      try {
        final tunnel = await _openTunnel(agent, agentPort, key, tunnelLocalPortFor(device.id));
        return RemoteDesktopEndpoint(
          host: InternetAddress.loopbackIPv4.address,
          port: tunnel.localPort,
          viaAgent: true,
          onClose: tunnel.close,
        );
      } on RdpTunnelException catch (error) {
        // Solo sin conexión se prueba la siguiente dirección.
        if (error.failure != RdpTunnelFailure.unreachable) {
          throw RemoteDesktopRouteException(error.message);
        }
      }
    }
    throw const RemoteDesktopRouteException(
      'No se pudo llegar al PC ni por la red local ni por el agente. '
      'Comprueba que esté encendido y, con datos móviles, que WARP esté activo.',
    );
  }
}
