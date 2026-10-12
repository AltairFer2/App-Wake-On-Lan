/// Bloquea temporalmente a un origen que acumula peticiones inválidas, para
/// frenar intentos de fuerza bruta o ruido en la red local.
class FailureRateLimiter {
  FailureRateLimiter({
    this.maxFailures = 10,
    this.window = const Duration(minutes: 1),
    this.blockDuration = const Duration(minutes: 5),
  });

  final int maxFailures;
  final Duration window;
  final Duration blockDuration;

  final Map<String, List<DateTime>> _failures = {};
  final Map<String, DateTime> _blockedUntil = {};

  bool isBlocked(String source, DateTime now) {
    final until = _blockedUntil[source];
    if (until == null) return false;
    if (now.isBefore(until)) return true;
    _blockedUntil.remove(source);
    return false;
  }

  void recordFailure(String source, DateTime now) {
    final recent = (_failures[source] ?? [])
      ..removeWhere((at) => now.difference(at) > window)
      ..add(now);
    _failures[source] = recent;
    if (recent.length >= maxFailures) {
      _blockedUntil[source] = now.add(blockDuration);
      _failures.remove(source);
    }
  }
}
