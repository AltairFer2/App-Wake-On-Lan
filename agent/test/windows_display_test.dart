@TestOn('windows')
library;

import 'package:altair_wake_agent/src/windows_display.dart';
import 'package:test/test.dart';

/// Llama a la API real de Windows: verifica las firmas FFI y la estructura
/// REASON_CONTEXT. La petición se libera al instante, sin efecto visible.
void main() {
  test('crea, renueva y libera la petición de pantalla', () {
    final keepAlive = DisplayKeepAlive();
    addTearDown(keepAlive.release);

    keepAlive.hold(const Duration(seconds: 30));
    expect(keepAlive.isActive, isTrue);

    keepAlive.hold(const Duration(seconds: 30));
    expect(keepAlive.isActive, isTrue);

    keepAlive.release();
    expect(keepAlive.isActive, isFalse);
  });

  test('liberar sin petición activa no falla', () {
    DisplayKeepAlive().release();
  });
}
