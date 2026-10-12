/// Recuerda los nonces aceptados durante [window] para rechazar peticiones
/// repetidas. Fuera de esa ventana la marca de tiempo ya las invalida.
class ReplayGuard {
  ReplayGuard({this.window = const Duration(minutes: 2), this.maxEntries = 4096});

  final Duration window;

  /// Límite de memoria ante una avalancha de peticiones válidas.
  final int maxEntries;

  final Map<String, DateTime> _seen = {};

  /// Devuelve `true` y registra [nonce] si no se había visto; `false` si es
  /// una repetición.
  bool accept(String nonce, DateTime now) {
    _seen.removeWhere((_, seenAt) => now.difference(seenAt) > window);
    if (_seen.containsKey(nonce)) return false;
    if (_seen.length >= maxEntries) _seen.remove(_seen.keys.first);
    _seen[nonce] = now;
    return true;
  }
}
