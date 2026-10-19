/// Banderas de evento de ratón del protocolo RDP (MS-RDPBCGR 2.2.8.1.1.3.1.1.3).
abstract final class PointerFlags {
  static const int move = 0x0800;
  static const int down = 0x8000;
  static const int leftButton = 0x1000;
  static const int rightButton = 0x2000;
  static const int wheel = 0x0200;
  static const int horizontalWheel = 0x0400;
  static const int wheelNegative = 0x0100;

  /// Un "clic" de rueda estándar de Windows.
  static const int wheelDelta = 120;

  /// Giro de rueda: hacia arriba (o a la derecha) si [positive]. El valor
  /// negativo se codifica en complemento a dos de 9 bits.
  static int wheelStep({required bool positive, bool horizontal = false}) {
    final axis = horizontal ? horizontalWheel : wheel;
    return positive
        ? axis | wheelDelta
        : axis | wheelNegative | ((0x200 - wheelDelta) & 0xFF);
  }
}

/// Códigos de tecla virtual de Windows (VK_*) usados por la app.
abstract final class VirtualKey {
  /// Marca de tecla extendida (`KBDEXT` de WinPR). Sin ella FreeRDP traduce
  /// flechas, Inicio, Fin y Supr a las del teclado numérico (con Bloq Num
  /// escriben dígitos) y la tecla Windows a ningún código.
  static const int extended = 0x0100;

  static const int backspace = 0x08;
  static const int tab = 0x09;
  static const int enter = 0x0D;
  static const int shift = 0x10;
  static const int control = 0x11;
  static const int alt = 0x12;
  static const int escape = 0x1B;
  static const int pageUp = 0x21 | extended;
  static const int pageDown = 0x22 | extended;
  static const int end = 0x23 | extended;
  static const int home = 0x24 | extended;
  static const int left = 0x25 | extended;
  static const int up = 0x26 | extended;
  static const int right = 0x27 | extended;
  static const int down = 0x28 | extended;
  static const int delete = 0x2E | extended;
  static const int windows = 0x5B | extended;

  /// VK de una letra o un dígito ASCII (los VK coinciden con su mayúscula);
  /// `null` para el resto, que se envía como Unicode.
  static int? ofCharacter(String character) {
    if (character.length != 1) return null;
    final upper = character.toUpperCase().codeUnitAt(0);
    final isLetter = upper >= 0x41 && upper <= 0x5A;
    final isDigit = upper >= 0x30 && upper <= 0x39;
    return isLetter || isDigit ? upper : null;
  }
}
