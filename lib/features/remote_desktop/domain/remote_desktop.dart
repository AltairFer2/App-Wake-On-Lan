import 'dart:io';

import '../../devices/domain/device.dart';

/// Puerto predeterminado del Escritorio remoto de Windows.
const int defaultRemoteDesktopPort = 3389;

/// "Windows App" de Microsoft (antes "Remote Desktop") en Google Play.
const String windowsAppPackage = 'com.microsoft.rdc.androidx';

/// Host para el escritorio remoto: la IPv4 local. RDP solo se habilita para
/// la red de casa; no se expone a Internet.
String? remoteDesktopHostOf(Device device) {
  final raw = device.localIpv4?.trim();
  if (raw == null || device.remoteDesktopPort == null) return null;
  final address = InternetAddress.tryParse(raw);
  return address?.type == InternetAddressType.IPv4 ? address!.address : null;
}

/// Ancho máximo del escritorio remoto pedido al PC: más píxeles solo
/// encarecen la transmisión en una pantalla de teléfono.
const int maxRemoteDesktopWidth = 1920;

/// Tamaño del escritorio remoto para una pantalla de [physicalWidth] x
/// [physicalHeight] píxeles: horizontal, con su misma proporción, limitado a
/// [maxRemoteDesktopWidth] y en múltiplos de 4 (exigencia de los códecs RDP).
({int width, int height}) remoteDesktopSizeFor(
  double physicalWidth,
  double physicalHeight,
) {
  final long = physicalWidth > physicalHeight ? physicalWidth : physicalHeight;
  final short = physicalWidth > physicalHeight ? physicalHeight : physicalWidth;
  final scale = long > maxRemoteDesktopWidth ? maxRemoteDesktopWidth / long : 1.0;
  int multipleOf4(double value) => (value * scale / 4).floor() * 4;
  return (width: multipleOf4(long), height: multipleOf4(short));
}

/// Enlace del cliente de Microsoft. Se arma como texto: `Uri` no acepta una
/// autoridad con este formato (`full%20address=s:host:puerto`).
String remoteDesktopLink(String host, int port) =>
    'rdp://full%20address=s:$host:$port';
