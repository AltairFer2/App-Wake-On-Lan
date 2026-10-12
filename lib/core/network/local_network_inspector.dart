import 'dart:io';

import 'ip_classification.dart';

/// Tipo de interfaz deducido de su nombre. Es una estimación: Android no
/// garantiza los nombres y `dart:io` no expone el tipo de transporte.
enum InterfaceKind { wifi, mobileData, vpn, ethernet, unknown }

class LocalInterface {
  const LocalInterface({required this.name, required this.addresses});

  final String name;
  final List<InternetAddress> addresses;

  InterfaceKind get kind => guessInterfaceKind(name);
}

class LocalNetworkSnapshot {
  const LocalNetworkSnapshot(this.interfaces);

  final List<LocalInterface> interfaces;

  Iterable<InternetAddress> get _allAddresses =>
      interfaces.expand((i) => i.addresses);

  /// IPv4 privadas del teléfono (típicamente la de la Wi-Fi doméstica).
  List<InternetAddress> get privateIpv4 => _allAddresses
      .where(
        (a) =>
            a.type == InternetAddressType.IPv4 &&
            IpClassification.scopeOf(a) == AddressScope.private,
      )
      .toList();

  List<InternetAddress> get globalIpv6 =>
      _allAddresses.where(IpClassification.isGlobalUnicastIpv6).toList();

  bool get hasGlobalIpv6 => globalIpv6.isNotEmpty;

  bool get isEmpty => interfaces.isEmpty;

  /// `true` si alguna IPv4 del teléfono comparte los tres primeros octetos con
  /// [ipv4]. Supone una máscara /24, la habitual en redes domésticas.
  bool sharesSlash24With(InternetAddress ipv4) {
    final target = ipv4.rawAddress;
    return privateIpv4.any((own) {
      final raw = own.rawAddress;
      return raw[0] == target[0] && raw[1] == target[1] && raw[2] == target[2];
    });
  }
}

InterfaceKind guessInterfaceKind(String name) {
  final lower = name.toLowerCase();
  if (lower.startsWith('wlan') || lower.startsWith('wifi')) {
    return InterfaceKind.wifi;
  }
  if (lower.startsWith('rmnet') ||
      lower.startsWith('ccmni') ||
      lower.startsWith('v4-rmnet') ||
      lower.startsWith('seth') ||
      lower.startsWith('pdp')) {
    return InterfaceKind.mobileData;
  }
  if (lower.startsWith('tun') ||
      lower.startsWith('ppp') ||
      lower.startsWith('wg')) {
    return InterfaceKind.vpn;
  }
  if (lower.startsWith('eth')) return InterfaceKind.ethernet;
  return InterfaceKind.unknown;
}

abstract interface class LocalNetworkInspector {
  Future<LocalNetworkSnapshot> inspect();
}

class SystemLocalNetworkInspector implements LocalNetworkInspector {
  const SystemLocalNetworkInspector();

  @override
  Future<LocalNetworkSnapshot> inspect() async {
    final interfaces = await NetworkInterface.list(includeLinkLocal: true);
    return LocalNetworkSnapshot([
      for (final nic in interfaces)
        LocalInterface(name: nic.name, addresses: nic.addresses),
    ]);
  }
}
