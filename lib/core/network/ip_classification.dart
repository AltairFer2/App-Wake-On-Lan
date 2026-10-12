import 'dart:io';

/// Alcance de una dirección desde el punto de vista de Internet.
enum AddressScope {
  /// IPv4 pública o IPv6 global unicast.
  public,

  /// RFC 1918 (10/8, 172.16/12, 192.168/16) o IPv6 ULA (fc00::/7).
  private,

  /// Espacio compartido de CGNAT, RFC 6598 (100.64.0.0/10).
  carrierGradeNat,

  /// Loopback, link-local, multicast, no especificada u otros rangos
  /// reservados que no sirven como destino remoto.
  nonRoutable,
}

abstract final class IpClassification {
  static AddressScope scopeOf(InternetAddress address) =>
      address.type == InternetAddressType.IPv4
          ? _ipv4Scope(address.rawAddress)
          : _ipv6Scope(address);

  /// `true` si la dirección puede recibir tráfico iniciado desde Internet
  /// (sin considerar NAT ni firewalls intermedios).
  static bool isInternetRoutable(InternetAddress address) =>
      scopeOf(address) == AddressScope.public;

  /// 2000::/3: el único bloque IPv6 asignado para unicast global.
  static bool isGlobalUnicastIpv6(InternetAddress address) =>
      address.type == InternetAddressType.IPv6 &&
      address.rawAddress[0] & 0xE0 == 0x20;

  static AddressScope _ipv4Scope(List<int> b) {
    final first = b[0];
    final second = b[1];
    if (first == 10 ||
        (first == 172 && second >= 16 && second <= 31) ||
        (first == 192 && second == 168)) {
      return AddressScope.private;
    }
    if (first == 100 && second >= 64 && second <= 127) {
      return AddressScope.carrierGradeNat;
    }
    if (first == 0 ||
        first == 127 ||
        (first == 169 && second == 254) ||
        first >= 224) {
      return AddressScope.nonRoutable;
    }
    return AddressScope.public;
  }

  static AddressScope _ipv6Scope(InternetAddress address) {
    if (isGlobalUnicastIpv6(address)) return AddressScope.public;
    if (address.rawAddress[0] & 0xFE == 0xFC) return AddressScope.private;
    return AddressScope.nonRoutable;
  }
}
