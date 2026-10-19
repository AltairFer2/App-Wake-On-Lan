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

  /// Monitor encuadrado (coordenadas del escritorio); `null` si se ve todo.
  Rect? get focusArea => _focusArea;
  Rect? _focusArea;

  /// Lo que se muestra: el monitor encuadrado o el escritorio completo. El
  /// zoom y el desplazamiento no salen de aquí.
  Rect get _area => _focusArea ?? Offset.zero & desktop;

  /// Escala con la que [_area] cabe entera en pantalla.
  double get fitScale => _screen.isEmpty ? 1 : _fitScaleOf(_area);

  /// Ajusta a un nuevo tamaño de pantalla (al abrir o al girar el teléfono)
  /// y vuelve a encajar lo que se estaba mostrando.
  void resize(Size screen) {
    if (screen == _screen) return;
    _screen = screen;
    _fit();
  }

  void showAll() {
    _focusArea = null;
    _fit();
  }

  /// Encaja [area] (en coordenadas del escritorio) centrada en pantalla y la
  /// recuerda para los cambios de tamaño.
  void focus(Rect area) {
    _focusArea = area;
    _fit();
  }

  /// Más cerca que el encuadre actual: solo entonces hay que seguir al puntero.
  bool get zoomedIn => scale > fitScale * 1.001;

  double _fitScaleOf(Rect area) =>
      math.min(_screen.width / area.width, _screen.height / area.height);

  void _fit() {
    if (_screen.isEmpty) return;
    scale = fitScale;
    _clamp();
  }

  /// Punto del escritorio bajo [screenPoint], recortado a sus límites.
  Offset toDesktop(Offset screenPoint) => clampToDesktop((screenPoint - origin) / scale);

  Offset toScreen(Offset desktopPoint) => origin + desktopPoint * scale;

  Offset clampToDesktop(Offset point) => Offset(
    point.dx.clamp(0, desktop.width - 1),
    point.dy.clamp(0, desktop.height - 1),
  );

  /// Como [toDesktop], pero sin salir del monitor encuadrado: lo que queda
  /// fuera está tapado y no debe recibir clics.
  Offset toVisibleDesktop(Offset screenPoint) {
    final point = toDesktop(screenPoint);
    final area = _focusArea;
    if (area == null) return point;
    return Offset(
      point.dx.clamp(area.left, area.right - 1),
      point.dy.clamp(area.top, area.bottom - 1),
    );
  }

  /// Rectángulo en pantalla de [area] (coordenadas del escritorio).
  Rect toScreenRect(Rect area) =>
      Rect.fromPoints(toScreen(area.topLeft), toScreen(area.bottomRight));

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

  /// Centra el eje de [_area] que cabe entero y limita el otro para no
  /// mostrar nada fuera de [_area].
  void _clamp() {
    final area = _area;
    double axis(double origin, double start, double end, double screen) {
      final content = (end - start) * scale;
      return content <= screen
          ? (screen - content) / 2 - start * scale
          : origin.clamp(screen - end * scale, -start * scale);
    }

    origin = Offset(
      axis(origin.dx, area.left, area.right, _screen.width),
      axis(origin.dy, area.top, area.bottom, _screen.height),
    );
  }
}
