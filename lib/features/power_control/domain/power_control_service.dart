import 'dart:io';

import 'package:altair_agent_protocol/altair_agent_protocol.dart';

import '../../../core/security/agent_key_store.dart';
import '../../devices/domain/device.dart';
import '../data/agent_client.dart';

/// Envía órdenes al agente de un dispositivo por la red local.
class PowerControlService {
  const PowerControlService({
    required this._client,
    required this._keyStore,
  });

  final AgentClient _client;
  final AgentKeyStore _keyStore;

  /// Lanza `StorageException` si la clave guardada no puede leerse.
  Future<AgentCallResult> run(Device device, AgentCommand command) async {
    final port = device.agentPort;
    final address = agentAddressOf(device);
    if (port == null || address == null) {
      return const AgentCallResult(
        AgentCallOutcome.unreachable,
        'El equipo no tiene agente configurado (requiere puerto e IP local).',
      );
    }
    final key = await _keyStore.read(device.id);
    if (key == null) {
      return const AgentCallResult(
        AgentCallOutcome.unauthorized,
        'No hay clave del agente guardada para este equipo.',
      );
    }
    return _client.send(address, port, key, command);
  }

  /// IPv4 local si existe; si no, la IPv6 del equipo.
  static InternetAddress? agentAddressOf(Device device) {
    for (final raw in [device.localIpv4, device.ipv6Address]) {
      final address = raw == null ? null : InternetAddress.tryParse(raw.trim());
      if (address != null) return address;
    }
    return null;
  }
}
