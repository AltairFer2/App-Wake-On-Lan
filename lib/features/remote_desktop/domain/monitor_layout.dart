import 'dart:math' as math;
import 'dart:ui';

/// Monitores del PC para el escritorio remoto, de izquierda a derecha y con
/// el principal primero. Se guardan como "1920x1080, 1920x1080, 1152x720".
///
/// Se asume una fila horizontal alineada arriba: cubre la disposición
/// habitual sin pedir coordenadas al usuario.
class MonitorLayout {
  MonitorLayout(List<Size> monitors) : monitors = List.unmodifiable(monitors);

  final List<Size> monitors;

  static final RegExp _entry = RegExp(r'^(\d{3,5})\s*[x×]\s*(\d{3,5})$');
  static const int maxMonitors = 16;
  static const int minSide = 200;
  static const int maxSide = 16384;

  /// Resoluciones que ofrece el selector del formulario.
  static const List<Size> commonResolutions = [
    Size(1280, 720),
    Size(1366, 768),
    Size(1600, 900),
    Size(1920, 1080),
    Size(1920, 1200),
    Size(2560, 1080),
    Size(2560, 1440),
    Size(3440, 1440),
    Size(3840, 2160),
  ];

  /// `null` si el texto está vacío o no es válido.
  static MonitorLayout? tryParse(String? text) {
    final trimmed = text?.trim() ?? '';
    if (trimmed.isEmpty) return null;
    final monitors = <Size>[];
    for (final part in trimmed.split(',')) {
      final size = tryParseResolution(part);
      if (size == null) return null;
      monitors.add(size);
    }
    if (monitors.length > maxMonitors) return null;
    return MonitorLayout(monitors);
  }

  /// Una resolución "1920x1080"; `null` si no es válida.
  static Size? tryParseResolution(String text) {
    final match = _entry.firstMatch(text.trim().toLowerCase());
    if (match == null) return null;
    final width = int.parse(match.group(1)!);
    final height = int.parse(match.group(2)!);
    bool valid(int side) => side >= minSide && side <= maxSide;
    if (!valid(width) || !valid(height)) return null;
    return Size(width.toDouble(), height.toDouble());
  }

  static String formatResolution(Size size) =>
      '${size.width.toInt()}x${size.height.toInt()}';

  /// Solo el monitor principal, con su resolución.
  MonitorLayout get primaryOnly => MonitorLayout([monitors.first]);

  /// Rectángulo de cada monitor dentro del escritorio virtual.
  List<Rect> get rects {
    final result = <Rect>[];
    var left = 0.0;
    for (final size in monitors) {
      result.add(Rect.fromLTWH(left, 0, size.width, size.height));
      left += size.width;
    }
    return result;
  }

  Size get bounds => Size(
    monitors.fold(0.0, (sum, size) => sum + size.width),
    monitors.fold(0.0, (highest, size) => math.max(highest, size.height)),
  );

  /// x, y, ancho, alto por monitor: el formato que espera el código nativo.
  List<int> toFlatList() => [
    for (final rect in rects) ...[
      rect.left.toInt(),
      rect.top.toInt(),
      rect.width.toInt(),
      rect.height.toInt(),
    ],
  ];

  String format() => monitors.map(formatResolution).join(', ');
}
