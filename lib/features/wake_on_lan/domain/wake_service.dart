import 'dart:io';
import 'dart:typed_data';

import '../../../core/network/address_resolver.dart';
import '../../../core/network/ip_classification.dart';
import '../../../core/network/magic_packet.dart';
import '../../../core/network/socket_failure.dart';
import '../../../core/network/udp_sender.dart';
import '../../devices/domain/device.dart';
import 'wake_report.dart';

/// Envía el paquete mágico por cada ruta configurada del dispositivo y
/// reporta el resultado local de cada envío. No confirma el encendido: eso
/// corresponde a [WakeConfirmer].
class WakeService {
  WakeService({
    required this._sender,
    required this._resolver,
    this.repetitions = 3,
    this.repetitionGap = const Duration(milliseconds: 100),
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final UdpSender _sender;
  final AddressResolver _resolver;
  final DateTime Function() _clock;

  /// UDP no garantiza entrega; repetir el envío compensa pérdidas puntuales.
  final int repetitions;
  final Duration repetitionGap;

  Future<WakeReport> wake(Device device) async {
    final payload = MagicPacket.build(device.mac);
    final routes = <WakeRouteResult>[await _sendLan(device, payload)];
    switch (device.remoteMode) {
      case RemoteAccessMode.none:
        break;
      case RemoteAccessMode.ipv4:
        routes.add(await _sendRemote(device, payload, WakeRouteKind.wanIpv4));
      case RemoteAccessMode.ipv6:
        routes.add(await _sendRemote(device, payload, WakeRouteKind.wanIpv6));
    }
    return WakeReport(at: _clock(), routes: routes);
  }

  Future<WakeRouteResult> _sendLan(Device device, Uint8List payload) async {
    final target = '${device.broadcastAddress}:${device.lanPort}';
    final address = InternetAddress.tryParse(device.broadcastAddress);
    if (address == null || address.type != InternetAddressType.IPv4) {
      return _result(
        WakeRouteKind.lanBroadcast,
        target,
        WakeRouteOutcome.invalidAddress,
        'La dirección de difusión debe ser una IPv4.',
      );
    }
    return _deliver(
      WakeRouteKind.lanBroadcast,
      payload,
      address,
      device.lanPort,
      broadcast: true,
      sentDetail:
          'Difusión enviada. Solo es efectiva si el teléfono está en la misma '
          'red local que el equipo.',
    );
  }

  Future<WakeRouteResult> _sendRemote(
    Device device,
    Uint8List payload,
    WakeRouteKind kind,
  ) async {
    final isIpv6 = kind == WakeRouteKind.wanIpv6;
    final host = device.remoteTarget;
    if (host == null) {
      return _result(
        kind,
        '—',
        WakeRouteOutcome.invalidAddress,
        'No hay dirección remota configurada.',
      );
    }
    final List<InternetAddress> addresses;
    try {
      addresses = await _resolver.resolve(
        host,
        isIpv6 ? InternetAddressType.IPv6 : InternetAddressType.IPv4,
      );
    } on AddressResolutionException catch (error) {
      return _result(
        kind,
        '$host:${device.remotePort}',
        WakeRouteOutcome.dnsFailure,
        error.message,
      );
    }
    final address = addresses.first;
    final target = _formatTarget(address, device.remotePort);
    switch (IpClassification.scopeOf(address)) {
      case AddressScope.public:
        return _deliver(
          kind,
          payload,
          address,
          device.remotePort,
          sentDetail: isIpv6
              ? 'Datagrama enviado a la IPv6 del equipo. Llegará solo si el '
                    'firewall IPv6 del router lo permite y el router aún '
                    'conoce la MAC del equipo (NDP).'
              : 'Datagrama enviado a la IPv4 pública. Llegará solo si el '
                    'router lo reenvía al equipo.',
        );
      case AddressScope.private:
      case AddressScope.carrierGradeNat:
        return _result(
          kind,
          target,
          WakeRouteOutcome.likelyBlockedByNat,
          '${address.address} es una dirección privada o de CGNAT: no es '
          'alcanzable desde Internet. Se requiere una IPv4 pública o IPv6.',
        );
      case AddressScope.nonRoutable:
        return _result(
          kind,
          target,
          WakeRouteOutcome.invalidAddress,
          '${address.address} no es enrutable en Internet.',
        );
    }
  }

  Future<WakeRouteResult> _deliver(
    WakeRouteKind kind,
    Uint8List payload,
    InternetAddress address,
    int port, {
    required String sentDetail,
    bool broadcast = false,
  }) async {
    final target = _formatTarget(address, port);
    try {
      for (var i = 0; i < repetitions; i++) {
        if (i > 0) await Future<void>.delayed(repetitionGap);
        await _sender.send(payload, address, port, broadcast: broadcast);
      }
      return _result(kind, target, WakeRouteOutcome.sent, sentDetail);
    } on SocketException catch (error) {
      final failure = classifySocketFailure(error);
      if (failure == SocketFailureKind.networkUnreachable) {
        return _result(
          kind,
          target,
          WakeRouteOutcome.noConnectivity,
          'El teléfono no tiene ruta hacia ese destino con la red actual.',
        );
      }
      return _result(
        kind,
        target,
        WakeRouteOutcome.socketError,
        'Error de socket: ${error.osError?.message ?? error.message}',
      );
    } on UdpSendException catch (error) {
      return _result(kind, target, WakeRouteOutcome.socketError, error.message);
    }
  }

  static String _formatTarget(InternetAddress address, int port) =>
      address.type == InternetAddressType.IPv6
          ? '[${address.address}]:$port'
          : '${address.address}:$port';

  static WakeRouteResult _result(
    WakeRouteKind kind,
    String target,
    WakeRouteOutcome outcome,
    String detail,
  ) => WakeRouteResult(
    kind: kind,
    target: target,
    outcome: outcome,
    detail: detail,
  );
}
