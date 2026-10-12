import 'dart:async';
import 'dart:io';

/// Falla al convertir un nombre de host en direcciones IP.
class AddressResolutionException implements Exception {
  const AddressResolutionException(this.message);

  final String message;

  @override
  String toString() => 'AddressResolutionException: $message';
}

abstract interface class AddressResolver {
  /// Resuelve [host] (literal o nombre DNS) a direcciones de la familia
  /// [type]. Lanza [AddressResolutionException] si no hay resultados.
  Future<List<InternetAddress>> resolve(String host, InternetAddressType type);
}

class SystemAddressResolver implements AddressResolver {
  const SystemAddressResolver({this.timeout = const Duration(seconds: 5)});

  final Duration timeout;

  @override
  Future<List<InternetAddress>> resolve(
    String host,
    InternetAddressType type,
  ) async {
    final literal = InternetAddress.tryParse(host);
    if (literal != null) {
      if (literal.type != type) {
        throw AddressResolutionException(
          '$host no es una dirección ${_familyName(type)}.',
        );
      }
      return [literal];
    }
    try {
      final addresses = await InternetAddress.lookup(
        host,
        type: type,
      ).timeout(timeout);
      if (addresses.isEmpty) {
        throw AddressResolutionException(
          '$host no tiene registros ${_recordName(type)}.',
        );
      }
      return addresses;
    } on TimeoutException {
      throw AddressResolutionException(
        'La consulta DNS de $host superó ${timeout.inSeconds} s.',
      );
    } on SocketException catch (error) {
      throw AddressResolutionException(
        'No se pudo resolver $host como ${_familyName(type)} '
        '(${error.osError?.message ?? error.message}).',
      );
    }
  }

  static String _familyName(InternetAddressType type) =>
      type == InternetAddressType.IPv6 ? 'IPv6' : 'IPv4';

  static String _recordName(InternetAddressType type) =>
      type == InternetAddressType.IPv6 ? 'AAAA' : 'A';
}
