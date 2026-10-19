import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/rdp_client.dart';
import '../domain/monitor_layout.dart';
import '../domain/rdp_input.dart';
import '../domain/rdp_viewport.dart';
import '../domain/remote_desktop.dart';
import '../domain/text_diff.dart';
import 'rdp_session_controller.dart';

/// Cómo se interpreta un dedo sobre el escritorio.
enum RdpControlMode {
  /// Touchpad: el dedo desplaza el puntero; tocar hace clic donde está.
  pointer('Puntero (touchpad)', Icons.mouse_outlined),

  /// El clic ocurre justo donde se toca.
  touch('Toque directo', Icons.touch_app_outlined),

  /// Un dedo mueve la vista ampliada; no envía nada al PC.
  view('Mover la vista', Icons.pan_tool_outlined);

  const RdpControlMode(this.label, this.icon);

  final String label;
  final IconData icon;
}

/// Escritorio remoto integrado: FreeRDP dibuja en una textura de Flutter.
///
/// Gestos comunes: tocar = clic; mantener = clic derecho; mantener y mover =
/// arrastrar; dos dedos = rueda; pellizcar = zoom. Ver [RdpControlMode].
class RdpSessionScreen extends StatefulWidget {
  const RdpSessionScreen({
    super.key,
    required this.client,
    required this.title,
    required this.host,
    required this.port,
    required this.username,
    required this.password,
    this.monitors,
  });

  final RdpClient client;
  final String title;
  final String host;
  final int port;
  final String username;
  final String password;

  /// Monitores a anunciar al PC (uno solo fija la resolución); `null` para
  /// uno ajustado a la pantalla del teléfono.
  final MonitorLayout? monitors;

  @override
  State<RdpSessionScreen> createState() => _RdpSessionScreenState();
}

class _RdpSessionScreenState extends State<RdpSessionScreen> {
  late final RdpSessionController _controller = RdpSessionController(widget.client)
    ..addListener(_onChange);
  bool _started = false;
  bool _certificateDialogOpen = false;
  RdpControlMode _mode = RdpControlMode.pointer;
  RdpViewport? _viewport;

  /// El escritorio es apaisado: horizontal por defecto, con botón para girar.
  bool _landscape = true;

  static const _landscapeOrientations = [
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ];

  @override
  void initState() {
    super.initState();
    _applyOrientation();
    // Barras del sistema ocultas; un deslizamiento desde el borde las muestra.
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  }

  void _applyOrientation() => SystemChrome.setPreferredOrientations(
    _landscape ? _landscapeOrientations : const [DeviceOrientation.portraitUp],
  );

  void _toggleOrientation() {
    setState(() => _landscape = !_landscape);
    _applyOrientation();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    final media = MediaQuery.of(context);
    final monitors = widget.monitors;
    final ({int width, int height}) size;
    if (monitors == null) {
      size = remoteDesktopSizeFor(
        media.size.width * media.devicePixelRatio,
        media.size.height * media.devicePixelRatio,
      );
    } else {
      size = (width: monitors.bounds.width.toInt(), height: monitors.bounds.height.toInt());
    }
    _controller.start(
      RdpConnectionRequest(
        host: widget.host,
        port: widget.port,
        username: widget.username,
        password: widget.password,
        width: size.width,
        height: size.height,
        monitorLayout: monitors?.toFlatList() ?? const [],
      ),
    );
  }

  @override
  void dispose() {
    _controller
      ..removeListener(_onChange)
      ..dispose();
    // Lista vacía: vuelve a la orientación que decida el sistema.
    SystemChrome.setPreferredOrientations(const []);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  void _onChange() {
    final size = _controller.desktopSize;
    if (size != null) {
      final desktop = Size(size.width.toDouble(), size.height.toDouble());
      if (_viewport?.desktop != desktop) _viewport = RdpViewport(desktop);
    }
    final request = _controller.pendingCertificate;
    if (request != null && !_certificateDialogOpen) {
      _certificateDialogOpen = true;
      _askCertificate(request);
    }
  }

  Future<void> _askCertificate(RdpCertificateRequest request) async {
    final accept = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => _CertificateDialog(request: request),
    );
    _certificateDialogOpen = false;
    await _controller.answerCertificate(accept: accept ?? false);
  }

  Future<void> _disconnect() async {
    await _controller.close();
    if (mounted) Navigator.of(context).pop();
  }

  void _showMonitor(Rect? area) {
    final viewport = _viewport;
    if (viewport == null) return;
    setState(() => area == null ? viewport.showAll() : viewport.focus(area));
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _controller,
      builder: (context, _) {
        final connected = _controller.phase == RdpPhase.connected;
        final monitorRects = widget.monitors?.rects ?? const <Rect>[];
        return Scaffold(
          backgroundColor: Colors.black,
          appBar: AppBar(
            title: Text(widget.title),
            actions: [
              if (connected) ...[
                PopupMenuButton<RdpControlMode>(
                  tooltip: 'Modo de control',
                  icon: Icon(_mode.icon),
                  initialValue: _mode,
                  onSelected: (mode) => setState(() => _mode = mode),
                  itemBuilder: (_) => [
                    for (final mode in RdpControlMode.values)
                      CheckedPopupMenuItem(
                        value: mode,
                        checked: mode == _mode,
                        child: Text(mode.label),
                      ),
                  ],
                ),
                if (monitorRects.length > 1)
                  PopupMenuButton<int>(
                    tooltip: 'Monitores',
                    icon: const Icon(Icons.desktop_windows_outlined),
                    onSelected: (index) =>
                        _showMonitor(index < 0 ? null : monitorRects[index]),
                    itemBuilder: (_) => [
                      const PopupMenuItem(value: -1, child: Text('Todos')),
                      for (var i = 0; i < monitorRects.length; i++)
                        PopupMenuItem(value: i, child: Text('Monitor ${i + 1}')),
                    ],
                  ),
              ],
              IconButton(
                tooltip: _landscape ? 'Ver en vertical' : 'Ver en horizontal',
                icon: const Icon(Icons.screen_rotation_outlined),
                onPressed: _toggleOrientation,
              ),
              IconButton(
                tooltip: 'Desconectar',
                icon: const Icon(Icons.link_off),
                onPressed: _disconnect,
              ),
            ],
          ),
          body: Column(
            children: [
              Expanded(child: _body()),
              if (connected) _KeyboardBar(controller: _controller),
            ],
          ),
        );
      },
    );
  }

  Widget _body() {
    final textureId = _controller.textureId;
    final viewport = _viewport;
    return switch (_controller.phase) {
      RdpPhase.failed => _Message(
        icon: Icons.error_outline,
        text: _controller.errorMessage ?? 'No se pudo conectar.',
      ),
      RdpPhase.closed => const _Message(
        icon: Icons.link_off,
        text: 'La sesión de escritorio remoto terminó.',
      ),
      _ when textureId == null || viewport == null || _controller.phase != RdpPhase.connected =>
        const _Message(text: 'Conectando…', showProgress: true),
      _ => _RemoteDesktopView(
        textureId: textureId,
        viewport: viewport,
        controller: _controller,
        mode: _mode,
      ),
    };
  }
}

/// Muestra la textura con zoom, dibuja el puntero y traduce los gestos a
/// ratón remoto según [RdpControlMode].
class _RemoteDesktopView extends StatefulWidget {
  const _RemoteDesktopView({
    required this.textureId,
    required this.viewport,
    required this.controller,
    required this.mode,
  });

  final int textureId;
  final RdpViewport viewport;
  final RdpSessionController controller;
  final RdpControlMode mode;

  @override
  State<_RemoteDesktopView> createState() => _RemoteDesktopViewState();
}

enum _Gesture { none, move, drag, pan, twoFingers }

class _RemoteDesktopViewState extends State<_RemoteDesktopView> {
  /// Desplazamiento de dos dedos (px) por cada paso de rueda.
  static const double _scrollStep = 40;

  /// Cambio de escala a partir del cual dos dedos hacen zoom y no rueda.
  static const double _zoomThreshold = 0.08;

  _Gesture _gesture = _Gesture.none;
  double _lastScale = 1;
  bool _zooming = false;
  Offset _scrollRemainder = Offset.zero;
  Offset _lastDesktopPoint = Offset.zero;

  /// Mantener pulsado: punto de partida y si ya se convirtió en arrastre.
  Offset _holdStart = Offset.zero;
  bool _holdDragging = false;

  RdpViewport get _viewport => widget.viewport;
  RdpSessionController get _remote => widget.controller;
  bool get _isPointer => widget.mode == RdpControlMode.pointer;

  /// Punto del escritorio al que apunta un toque: el puntero en modo
  /// touchpad, o lo que está bajo el dedo en toque directo.
  Offset _target(Offset screenPoint) =>
      _isPointer ? _remote.cursor.value : _viewport.toDesktop(screenPoint);

  /// En modo touchpad el puntero recorre en pantalla lo mismo que el dedo.
  Offset _cursorAfter(Offset start, Offset screenDelta) =>
      _viewport.clampToDesktop(start + screenDelta / _viewport.scale);

  void _moveCursor(Offset point) {
    _remote.moveTo(point);
    if (_viewport.reveal(point)) setState(() {});
  }

  void _onTapUp(TapUpDetails details) {
    if (widget.mode == RdpControlMode.view) return;
    _remote.click(_target(details.localPosition));
  }

  void _onLongPressStart(LongPressStartDetails details) {
    if (widget.mode == RdpControlMode.view) return;
    HapticFeedback.mediumImpact();
    _holdStart = _target(details.localPosition);
    _holdDragging = false;
  }

  void _onLongPressMoveUpdate(LongPressMoveUpdateDetails details) {
    if (widget.mode == RdpControlMode.view) return;
    if (!_holdDragging) {
      _holdDragging = true;
      _remote.pressLeft(_holdStart);
    }
    _lastDesktopPoint = _isPointer
        ? _cursorAfter(_holdStart, details.localOffsetFromOrigin)
        : _viewport.toDesktop(details.localPosition);
    _moveCursor(_lastDesktopPoint);
  }

  /// Sin moverse es clic derecho; tras moverse, suelta el arrastre.
  void _onLongPressEnd(LongPressEndDetails details) {
    if (widget.mode == RdpControlMode.view) return;
    if (_holdDragging) {
      _remote.releaseLeft(_lastDesktopPoint);
    } else {
      _remote.click(_holdStart, right: true);
    }
    _holdDragging = false;
  }

  void _onScaleStart(ScaleStartDetails details) {
    _lastScale = 1;
    _zooming = false;
    _scrollRemainder = Offset.zero;
    if (details.pointerCount >= 2) {
      _gesture = _Gesture.twoFingers;
      return;
    }
    switch (widget.mode) {
      case RdpControlMode.pointer:
        _gesture = _Gesture.move;
      case RdpControlMode.touch:
        _gesture = _Gesture.drag;
        _lastDesktopPoint = _viewport.toDesktop(details.localFocalPoint);
        _remote.pressLeft(_lastDesktopPoint);
      case RdpControlMode.view:
        _gesture = _Gesture.pan;
    }
  }

  void _onScaleUpdate(ScaleUpdateDetails details) {
    switch (_gesture) {
      case _Gesture.move:
        _moveCursor(_cursorAfter(_remote.cursor.value, details.focalPointDelta));
      case _Gesture.drag:
        _lastDesktopPoint = _viewport.toDesktop(details.localFocalPoint);
        _remote.moveTo(_lastDesktopPoint);
      case _Gesture.pan:
        setState(() => _viewport.panBy(details.focalPointDelta));
      case _Gesture.twoFingers:
        if (!_zooming && (details.scale - 1).abs() > _zoomThreshold) _zooming = true;
        if (_zooming) {
          setState(() {
            _viewport
              ..zoomAt(details.localFocalPoint, details.scale / _lastScale)
              ..panBy(details.focalPointDelta);
          });
          _lastScale = details.scale;
        } else {
          _scrollBy(details.focalPointDelta, details.localFocalPoint);
        }
      case _Gesture.none:
        break;
    }
  }

  void _onScaleEnd(ScaleEndDetails details) {
    if (_gesture == _Gesture.drag) _remote.releaseLeft(_lastDesktopPoint);
    _gesture = _Gesture.none;
  }

  /// Acumula el desplazamiento de dos dedos en pasos de rueda. Desplazar los
  /// dedos hacia abajo muestra lo de arriba, como en una pantalla táctil.
  void _scrollBy(Offset delta, Offset focal) {
    _scrollRemainder += delta;
    final point = _target(focal);
    while (_scrollRemainder.dy.abs() >= _scrollStep) {
      final down = _scrollRemainder.dy > 0;
      _remote.scroll(point, towardsTop: down);
      _scrollRemainder -= Offset(0, down ? _scrollStep : -_scrollStep);
    }
    while (_scrollRemainder.dx.abs() >= _scrollStep) {
      final right = _scrollRemainder.dx > 0;
      _remote.scroll(point, towardsTop: !right, horizontal: true);
      _scrollRemainder -= Offset(right ? _scrollStep : -_scrollStep, 0);
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        _viewport.resize(constraints.biggest);
        final desktop = _viewport.desktop;
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapUp: _onTapUp,
          onLongPressStart: _onLongPressStart,
          onLongPressMoveUpdate: _onLongPressMoveUpdate,
          onLongPressEnd: _onLongPressEnd,
          onScaleStart: _onScaleStart,
          onScaleUpdate: _onScaleUpdate,
          onScaleEnd: _onScaleEnd,
          child: ClipRect(
            child: Stack(
              children: [
                Positioned(
                  left: _viewport.origin.dx,
                  top: _viewport.origin.dy,
                  width: desktop.width * _viewport.scale,
                  height: desktop.height * _viewport.scale,
                  child: Texture(
                    textureId: widget.textureId,
                    filterQuality: FilterQuality.medium,
                  ),
                ),
                ValueListenableBuilder<Offset>(
                  valueListenable: _remote.cursor,
                  builder: (context, cursor, _) {
                    final tip = _viewport.toScreen(cursor);
                    return Positioned(
                      left: tip.dx,
                      top: tip.dy,
                      child: const IgnorePointer(child: _CursorArrow()),
                    );
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// Flecha de ratón con la punta en la esquina superior izquierda. La dibuja
/// la app porque el PC no la incluye en la imagen del escritorio.
class _CursorArrow extends StatelessWidget {
  const _CursorArrow();

  static const Size _size = Size(16, 24);

  @override
  Widget build(BuildContext context) =>
      const CustomPaint(size: _size, painter: _CursorPainter());
}

class _CursorPainter extends CustomPainter {
  const _CursorPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final arrow = Path()
      ..moveTo(0, 0)
      ..lineTo(0, h * 0.85)
      ..lineTo(w * 0.3, h * 0.62)
      ..lineTo(w * 0.5, h)
      ..lineTo(w * 0.68, h * 0.92)
      ..lineTo(w * 0.48, h * 0.56)
      ..lineTo(w, h * 0.56)
      ..close();
    canvas
      ..drawPath(arrow, Paint()..color = Colors.white)
      ..drawPath(
        arrow,
        Paint()
          ..color = Colors.black
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5
          ..strokeJoin = StrokeJoin.round,
      );
  }

  @override
  bool shouldRepaint(_CursorPainter oldDelegate) => false;
}

/// Teclas especiales, modificadores y teclado del teléfono.
class _KeyboardBar extends StatefulWidget {
  const _KeyboardBar({required this.controller});

  final RdpSessionController controller;

  @override
  State<_KeyboardBar> createState() => _KeyboardBarState();
}

class _KeyboardBarState extends State<_KeyboardBar> {
  /// El campo nunca queda vacío: así el borrado se detecta como un cambio.
  static const String _sentinel = '​';

  /// Longitud a partir de la cual el campo se vacía (tras un espacio, sin
  /// palabra en composición) para no acumular texto.
  static const int _resetLength = 64;

  final _input = TextEditingController(text: _sentinel);
  final _focus = FocusNode();

  /// Lo que el PC ya recibió de este campo.
  String _sent = _sentinel;

  @override
  void dispose() {
    _input.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _toggleKeyboard() {
    if (_focus.hasFocus) {
      _focus.unfocus();
    } else {
      _focus.requestFocus();
      SystemChannels.textInput.invokeMethod<void>('TextInput.show');
    }
  }

  /// El teclado del teléfono edita el campo como texto normal (sugerencias,
  /// escritura deslizando, autocorrección); al PC se envía solo la
  /// diferencia: retrocesos por lo borrado y el texto nuevo.
  void _onChanged(String value) {
    final edit = TextDiff.between(_sent, value);
    final remote = widget.controller;
    for (var i = 0; i < edit.deleted; i++) {
      remote.pressKey(VirtualKey.backspace);
    }
    for (final character in edit.inserted.characters) {
      if (character == '\n') {
        remote.pressKey(VirtualKey.enter);
      } else {
        remote.typeText(character);
      }
    }
    _sent = value;
    if (_shouldReset(value)) {
      _sent = _sentinel;
      _input.value = const TextEditingValue(
        text: _sentinel,
        selection: TextSelection.collapsed(offset: _sentinel.length),
      );
    }
  }

  bool _shouldReset(String value) {
    if (!value.startsWith(_sentinel) || value.endsWith('\n')) return true;
    final composing = _input.value.composing;
    final idle = !composing.isValid || composing.isCollapsed;
    return idle && value.length > _resetLength && value.endsWith(' ');
  }

  @override
  Widget build(BuildContext context) {
    final remote = widget.controller;
    Widget key(String label, int virtualKey) => _BarButton(
      label: label,
      onPressed: () => remote.pressKey(virtualKey),
    );
    Widget modifier(String label, int virtualKey) => _BarButton(
      label: label,
      selected: remote.activeModifiers.contains(virtualKey),
      onPressed: () => remote.toggleModifier(virtualKey),
    );
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainer,
      child: SafeArea(
        top: false,
        child: Row(
          children: [
            IconButton(
              tooltip: 'Teclado',
              icon: const Icon(Icons.keyboard_outlined),
              onPressed: _toggleKeyboard,
            ),
            // Campo invisible que recibe el teclado del teléfono.
            SizedBox(
              width: 1,
              height: 1,
              child: Opacity(
                opacity: 0,
                child: TextField(
                  controller: _input,
                  focusNode: _focus,
                  // Sin sugerencias Android muestra un teclado de contraseña:
                  // sin predicción ni escritura deslizando.
                  autocorrect: false,
                  keyboardType: TextInputType.multiline,
                  textInputAction: TextInputAction.newline,
                  maxLines: null,
                  onChanged: _onChanged,
                ),
              ),
            ),
            Expanded(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    key('Esc', VirtualKey.escape),
                    key('Tab', VirtualKey.tab),
                    modifier('Ctrl', VirtualKey.control),
                    modifier('Alt', VirtualKey.alt),
                    modifier('Win', VirtualKey.windows),
                    key('←', VirtualKey.left),
                    key('↑', VirtualKey.up),
                    key('↓', VirtualKey.down),
                    key('→', VirtualKey.right),
                    key('Supr', VirtualKey.delete),
                    key('Inicio', VirtualKey.home),
                    key('Fin', VirtualKey.end),
                    key('RePág', VirtualKey.pageUp),
                    key('AvPág', VirtualKey.pageDown),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _BarButton extends StatelessWidget {
  const _BarButton({required this.label, required this.onPressed, this.selected = false});

  final String label;
  final VoidCallback onPressed;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: selected
          ? FilledButton(onPressed: onPressed, child: Text(label))
          : TextButton(onPressed: onPressed, child: Text(label)),
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({required this.text, this.icon, this.showProgress = false});

  final String text;
  final IconData? icon;
  final bool showProgress;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (showProgress) const CircularProgressIndicator(),
            if (icon != null) Icon(icon, size: 48, color: Colors.white70),
            const SizedBox(height: 16),
            Text(
              text,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white),
            ),
          ],
        ),
      ),
    );
  }
}

class _CertificateDialog extends StatelessWidget {
  const _CertificateDialog({required this.request});

  final RdpCertificateRequest request;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final mono = theme.textTheme.bodySmall?.copyWith(fontFamily: 'monospace');
    return AlertDialog(
      icon: Icon(
        request.changed ? Icons.gpp_bad_outlined : Icons.verified_user_outlined,
        color: request.changed ? theme.colorScheme.error : null,
      ),
      title: Text(request.changed ? 'El certificado cambió' : 'Verificar el equipo'),
      content: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              request.changed
                  ? 'El equipo ${request.host} presenta un certificado distinto '
                        'al que aceptaste antes. Puede deberse a una '
                        'reinstalación de Windows o a que otro equipo intenta '
                        'suplantarlo. Acéptalo solo si sabes por qué cambió.'
                  : 'Es la primera conexión con ${request.host}. Windows usa '
                        'un certificado propio; compara la huella con la del '
                        'PC si quieres asegurarte. Se recordará para las '
                        'próximas conexiones.',
            ),
            const SizedBox(height: 12),
            Text('Huella', style: theme.textTheme.labelMedium),
            SelectableText(request.fingerprint, style: mono),
            if (request.previousFingerprint case final previous?) ...[
              const SizedBox(height: 8),
              Text('Huella anterior', style: theme.textTheme.labelMedium),
              SelectableText(previous, style: mono),
            ],
            const SizedBox(height: 8),
            Text('Emitido para', style: theme.textTheme.labelMedium),
            Text(request.subject, style: mono),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Rechazar'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: const Text('Aceptar'),
        ),
      ],
    );
  }
}
