import 'package:flutter/widgets.dart' show StringCharacters;

/// Cambio entre dos versiones de un texto que se edita por el final:
/// [deleted] caracteres a borrar (retroceso) y luego [inserted] a escribir.
///
/// Cubre lo que hace el teclado del teléfono: escribir, borrar, completar una
/// palabra deslizando o sustituirla con una sugerencia.
class TextDiff {
  const TextDiff(this.deleted, this.inserted);

  /// Caracteres visibles (grafemas) a borrar del final.
  final int deleted;
  final String inserted;

  static TextDiff between(String before, String after) {
    final limit = before.length < after.length ? before.length : after.length;
    var prefix = 0;
    while (prefix < limit && before.codeUnitAt(prefix) == after.codeUnitAt(prefix)) {
      prefix++;
    }
    // No partir un par sustituto (emoji y similares).
    if (prefix > 0 && _isHighSurrogate(before.codeUnitAt(prefix - 1))) prefix--;
    return TextDiff(
      before.substring(prefix).characters.length,
      after.substring(prefix),
    );
  }

  static bool _isHighSurrogate(int unit) => unit >= 0xD800 && unit <= 0xDBFF;
}
