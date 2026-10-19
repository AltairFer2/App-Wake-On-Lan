import 'dart:math' as math;
import 'dart:ui';

/// Relación entre la pantalla del teléfono y el escritorio remoto: escala y
/// desplazamiento, con zoom limitado y sin dejar huecos innecesarios.
///
/// pantalla = origen + escritorio × escala
class RdpViewport {
  RdpViewport(this.desktop);

  final Size desktop;
  Size _screen = Size.zero;
  double scale = 1;
  Offset origin = Offset.zero;

  static const double maxZoom = 8;

  /// Escala con la que todo el escritorio cabe en pantalla.
  double get fitScale => _screen.isEmpty
      ? 1
      : math.min(_screen.width / desktop.width, _screen.height / desktop.height);

  /// Ajusta a un nuevo tamaño de pantalla. Al primer uso (o si cambia) muestra
  /// el escritorio completo.
  void resize(Size screen) {
    if (screen == _screen) return;
    _screen = screen;
    showAll();
  }

  void showAll() => focus(Offset.zero & desktop);

  /// Encaja [area] (en coordenadas del escritorio) centrada en pantalla.
  void focus(Rect area) {
    if (_screen.isEmpty) return;
    scale = math.min(_screen.width / area.width, _screen.height / area.height);
    origin = _screen.center(Offset.zero) - area.center * scale;
    _clamp();
  }

  /// Punto del escritorio bajo [screenPoint], recortado a sus límites.
  Offset toDesktop(Offset screenPoint) => clampToDesktop((screenPoint - origin) / scale);

  Offset toScreen(Offset desktopPoint) => origin + desktopPoint * scale;

  Offset clampToDesktop(Offset point) => Offset(
    point.dx.clamp(0, desktop.width - 1),
    point.dy.clamp(0, desktop.height - 1),
  );

  /// Desplaza la vista lo justo para que [desktopPoint] quede a [margin] del
  /// borde. Devuelve `true` si la vista cambió.
  bool reveal(Offset desktopPoint, {double margin = 32}) {
    final point = toScreen(desktopPoint);
    double shift(double position, double screen) {
      if (position < margin) return margin - position;
      if (position > screen - margin) return screen - margin - position;
      return 0;
    }

    final before = origin;
    panBy(Offset(shift(point.dx, _screen.width), shift(point.dy, _screen.height)));
    return origin != before;
  }

  /// Zoom multiplicando la escala por [factor] sin mover [focal].
  void zoomAt(Offset focal, double factor) {
    final target = (scale * factor).clamp(fitScale, fitScale * maxZoom);
    origin = focal - (focal - origin) * (target / scale);
    scale = target;
    _clamp();
  }

  void panBy(Offset delta) {
    origin += delta;
    _clamp();
  }

  /// Centra el eje que cabe entero y limita el otro para no mostrar fondo.
  void _clamp() {
    double axis(double origin, double content, double screen) => content <= screen
        ? (screen - content) / 2
        : origin.clamp(screen - content, 0);
    origin = Offset(
      axis(origin.dx, desktop.width * scale, _screen.width),
      axis(origin.dy, desktop.height * scale, _screen.height),
    );
  }
}
