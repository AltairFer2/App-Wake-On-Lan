import 'dart:math';

/// Genera identificadores aleatorios de 128 bits en hexadecimal.
String generateId() {
  final random = Random.secure();
  return List.generate(
    16,
    (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
}
