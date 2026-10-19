import 'dart:io';

import 'package:altair_agent_protocol/altair_agent_protocol.dart';

import '../../../core/security/agent_key_store.dart';
import '../../devices/domain/device.dart';
import '../data/agent_client.dart';

/// Envía órdenes al agente de un dispositivo, en la red local o por IPv6.
class PowerControlService {
  const PowerControlService({
    required this._client,
    required this._keyStore,
  });

  final AgentClient _client;
  final AgentKeyStore _keyStore;

  /// Prueba las direcciones en orden y pasa a la siguiente solo si no hubo
  /// conexión: si la orden llegó, repetirla podría ejecutarla dos veces.
  ///
  /// Lanza `StorageException` si la clave guardada no puede leerse.
  Future<AgentCallResult> run(Device device, AgentCommand command) async {
    final port = device.agentPort;
    final addresses = agentAddressesOf(device);
    if (port == null || addresses.isEmpty) {
      return const AgentCallResult(
        AgentCallOutcome.unreachable,
        'El equipo no tiene agente configurado (requiere puerto y una IP).',
      );
    }
    final key = await _keyStore.read(device.id);
    if (key == null) {
      return const AgentCallResult(
        AgentCallOutcome.unauthorized,
        'No hay clave del agente guardada para este equipo.',
      );
    }
    late AgentCallResult result;
    for (final address in addresses) {
      result = await _client.send(address, port, key, command);
      if (result.outcome != AgentCallOutcome.unreachable) break;
    }
    return result;
  }

  /// IPv4 local primero (en casa) y después la IPv6 global (desde fuera).
  static List<InternetAddress> agentAddressesOf(Device device) => [
    for (final raw in [device.localIpv4, device.ipv6Address])
      if (raw != null && InternetAddress.tryParse(raw.trim()) != null)
        InternetAddress(raw.trim()),
  ];
}
