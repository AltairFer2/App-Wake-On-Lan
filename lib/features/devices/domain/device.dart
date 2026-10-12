import '../../../core/network/mac_address.dart';
import '../../../core/network/network_validators.dart';

/// Ruta adicional para enviar el paquete mágico desde fuera de la LAN.
enum RemoteAccessMode {
  /// Solo red local.
  none,

  /// UDP hacia una IPv4 pública con reenvío de puerto en el router.
  ipv4,

  /// UDP hacia la IPv6 global del equipo, permitido por el firewall IPv6.
  ipv6,
}

/// Resultado persistido del último intento de encendido.
enum WakeAttemptStatus {
  /// El paquete salió por todas las rutas configuradas; sin confirmar.
  sent,

  /// Salió por algunas rutas y falló en otras; sin confirmar.
  partiallySent,

  /// No salió por ninguna ruta.
  notSent,

  /// El sondeo detectó al equipo después del envío.
  confirmedAwake,

  /// Se envió, pero el sondeo no pudo confirmar el encendido.
  notConfirmed,
}

class LastWakeAttempt {
  const LastWakeAttempt({required this.at, required this.status});

  final DateTime at;
  final WakeAttemptStatus status;

  Map<String, Object?> toJson() => {
    'at': at.toUtc().toIso8601String(),
    'status': status.name,
  };

  static LastWakeAttempt fromJson(Map<String, Object?> json) => LastWakeAttempt(
    at: DateTime.parse(_require<String>(json, 'at')).toLocal(),
    status: WakeAttemptStatus.values.byName(_require<String>(json, 'status')),
  );
}

/// Computadora registrada. No contiene secretos: la MAC y las direcciones son
/// identificadores de red, no credenciales.
class Device {
  const Device({
    required this.id,
    required this.name,
    required this.mac,
    this.localIpv4,
    this.broadcastAddress = limitedBroadcastAddress,
    this.lanPort = defaultWakeOnLanPort,
    this.ipv6Address,
    this.remoteMode = RemoteAccessMode.none,
    this.remoteHost,
    this.remotePort = defaultWakeOnLanPort,
    this.probePort,
    this.agentPort,
    this.lastAttempt,
  });

  final String id;
  final String name;
  final MacAddress mac;

  /// IPv4 reservada por DHCP; se usa para el sondeo de alcance en la LAN.
  final String? localIpv4;

  /// Destino de difusión en la LAN (limitada o dirigida, ej. 192.168.100.255).
  final String broadcastAddress;
  final int lanPort;

  /// IPv6 global del equipo. Destino del modo IPv6 si no hay [remoteHost].
  final String? ipv6Address;
  final RemoteAccessMode remoteMode;

  /// Nombre DNS o literal IP para el envío remoto.
  final String? remoteHost;
  final int remotePort;

  /// Puerto TCP para el sondeo de alcance. `null` desactiva el sondeo.
  final int? probePort;

  /// Puerto TCP del agente de Windows (estado, suspender, apagar). `null` si
  /// el equipo no tiene agente. La clave se guarda aparte, cifrada.
  final int? agentPort;
  final LastWakeAttempt? lastAttempt;

  /// Host al que se envía la ruta remota: [remoteHost] o, en modo IPv6 sin
  /// host explícito, [ipv6Address]. `null` si no hay ruta remota utilizable.
  String? get remoteTarget {
    if (remoteMode == RemoteAccessMode.none) return null;
    final remote = remoteHost?.trim();
    if (remote != null && remote.isNotEmpty) return remote;
    final ipv6 = ipv6Address?.trim();
    if (remoteMode == RemoteAccessMode.ipv6 && ipv6 != null && ipv6.isNotEmpty) {
      return ipv6;
    }
    return null;
  }

  Device withLastAttempt(LastWakeAttempt attempt) => Device(
    id: id,
    name: name,
    mac: mac,
    localIpv4: localIpv4,
    broadcastAddress: broadcastAddress,
    lanPort: lanPort,
    ipv6Address: ipv6Address,
    remoteMode: remoteMode,
    remoteHost: remoteHost,
    remotePort: remotePort,
    probePort: probePort,
    agentPort: agentPort,
    lastAttempt: attempt,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'mac': mac.toString(),
    'localIpv4': localIpv4,
    'broadcastAddress': broadcastAddress,
    'lanPort': lanPort,
    'ipv6Address': ipv6Address,
    'remoteMode': remoteMode.name,
    'remoteHost': remoteHost,
    'remotePort': remotePort,
    'probePort': probePort,
    'agentPort': agentPort,
    'lastAttempt': lastAttempt?.toJson(),
  };

  /// Lanza [FormatException] si falta un campo obligatorio o es inválido.
  static Device fromJson(Map<String, Object?> json) {
    final lastAttempt = json['lastAttempt'];
    final device = Device(
      id: _require<String>(json, 'id'),
      name: _require<String>(json, 'name'),
      mac: MacAddress.parse(_require<String>(json, 'mac')),
      localIpv4: json['localIpv4'] as String?,
      broadcastAddress: _require<String>(json, 'broadcastAddress'),
      lanPort: _require<int>(json, 'lanPort'),
      ipv6Address: json['ipv6Address'] as String?,
      remoteMode: RemoteAccessMode.values.byName(
        _require<String>(json, 'remoteMode'),
      ),
      remoteHost: json['remoteHost'] as String?,
      remotePort: _require<int>(json, 'remotePort'),
      probePort: json['probePort'] as int?,
      // Opcional: ausente en datos guardados antes de existir el agente.
      agentPort: json['agentPort'] as int?,
      lastAttempt: lastAttempt is Map<String, Object?>
          ? LastWakeAttempt.fromJson(lastAttempt)
          : null,
    );
    for (final port in [
      device.lanPort,
      device.remotePort,
      ?device.probePort,
      ?device.agentPort,
    ]) {
      if (!PortValidator.isValid(port)) {
        throw FormatException('Puerto fuera de rango en "${device.name}".', port);
      }
    }
    return device;
  }
}

T _require<T>(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! T) {
    throw FormatException('Campo "$key" ausente o con tipo inválido.', json);
  }
  return value;
}
