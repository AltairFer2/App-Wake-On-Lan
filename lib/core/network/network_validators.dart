import 'dart:io';

import 'ip_classification.dart';

/// Puerto UDP habitual para Wake-on-LAN. Es una convención (discard), no un
/// requisito del protocolo: la tarjeta busca el patrón en cualquier trama.
const int defaultWakeOnLanPort = 9;

/// Difusión limitada IPv4; solo alcanza el segmento al que está conectado el
/// teléfono.
const String limitedBroadcastAddress = '255.255.255.255';

abstract final class PortValidator {
  static const int min = 1;
  static const int max = 65535;

  static bool isValid(int port) => port >= min && port <= max;

  static String? validate(String? input, {bool required = true}) {
    final value = input?.trim() ?? '';
    if (value.isEmpty) {
      return required ? 'Ingresa un puerto.' : null;
    }
    final port = int.tryParse(value);
    if (port == null || !isValid(port)) {
      return 'El puerto debe ser un número entre $min y $max.';
    }
    return null;
  }
}

enum HostKind { ipv4, ipv6, hostname }

abstract final class HostValidator {
  static const int _maxHostnameLength = 253;
  static final RegExp _label = RegExp(
    r'^[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?$',
  );
  static final RegExp _digitsOnly = RegExp(r'^[0-9]+$');

  /// Clasifica [input] como literal IPv4, literal IPv6 o nombre DNS (RFC 1123).
  /// Devuelve `null` si no es ninguno de ellos.
  static HostKind? classify(String input) {
    final value = input.trim();
    if (value.isEmpty) return null;
    final literal = InternetAddress.tryParse(value);
    if (literal != null) {
      return literal.type == InternetAddressType.IPv4
          ? HostKind.ipv4
          : HostKind.ipv6;
    }
    return _isHostname(value) ? HostKind.hostname : null;
  }

  static String? validateIpv4(String? input, {bool required = false}) {
    final value = input?.trim() ?? '';
    if (value.isEmpty) return required ? 'Ingresa una dirección IPv4.' : null;
    final address = InternetAddress.tryParse(value);
    if (address == null || address.type != InternetAddressType.IPv4) {
      return 'Dirección IPv4 no válida (ej. 192.168.100.20).';
    }
    return null;
  }

  /// Exige una IPv6 global unicast: las direcciones link-local o ULA no son
  /// alcanzables desde Internet.
  static String? validateGlobalIpv6(String? input, {bool required = false}) {
    final value = input?.trim() ?? '';
    if (value.isEmpty) return required ? 'Ingresa una dirección IPv6.' : null;
    final address = InternetAddress.tryParse(value);
    if (address == null || address.type != InternetAddressType.IPv6) {
      return 'Dirección IPv6 no válida.';
    }
    if (!IpClassification.isGlobalUnicastIpv6(address)) {
      return 'Usa la IPv6 global del equipo (empieza por 2 o 3), '
          'no una link-local (fe80::) ni ULA (fc00::/fd00::).';
    }
    return null;
  }

  /// Valida un destino remoto según el modo: IPv4 o nombre DNS para
  /// [HostKind.ipv4]; IPv6 o nombre DNS para [HostKind.ipv6].
  static String? validateRemoteHost(
    String? input, {
    required HostKind family,
    bool required = true,
  }) {
    final value = input?.trim() ?? '';
    if (value.isEmpty) {
      return required ? 'Ingresa la dirección remota o un nombre DNS.' : null;
    }
    final kind = classify(value);
    if (kind == null) return 'Dirección o nombre de host no válido.';
    if (kind == HostKind.hostname) return null;
    if (family == HostKind.ipv4 && kind != HostKind.ipv4) {
      return 'El modo IPv4 requiere una dirección IPv4 o un nombre DNS.';
    }
    if (family == HostKind.ipv6) {
      if (kind != HostKind.ipv6) {
        return 'El modo IPv6 requiere una dirección IPv6 o un nombre DNS.';
      }
      return validateGlobalIpv6(value);
    }
    return null;
  }

  static bool _isHostname(String value) {
    final host = value.endsWith('.')
        ? value.substring(0, value.length - 1)
        : value;
    if (host.isEmpty || host.length > _maxHostnameLength) return false;
    final labels = host.split('.');
    if (!labels.every(_label.hasMatch)) return false;
    // Un último segmento numérico indica una IPv4 mal escrita, no un dominio.
    return !_digitsOnly.hasMatch(labels.last);
  }
}
