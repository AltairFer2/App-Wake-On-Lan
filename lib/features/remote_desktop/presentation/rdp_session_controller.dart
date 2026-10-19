import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

import '../data/rdp_client.dart';
import '../domain/rdp_input.dart';

enum RdpPhase { connecting, connected, failed, closed }

/// Estado de una sesión de escritorio remoto integrada.
class RdpSessionController extends ChangeNotifier {
  RdpSessionController(this._client);

  final RdpClient _client;
  StreamSubscription<RdpEvent>? _subscription;
  bool _closed = false;

  RdpPhase phase = RdpPhase.connecting;
  int? textureId;
  ({int width, int height})? desktopSize;
  String? errorMessage;

  /// Certificado pendiente de confirmar por el usuario.
  RdpCertificateRequest? pendingCertificate;

  /// Ctrl, Alt o Win pulsados en la barra: se aplican a la siguiente tecla.
  final Set<int> activeModifiers = {};

  /// Posición del ratón remoto (coordenadas del escritorio). Notificador
  /// propio para redibujar solo el puntero, no toda la pantalla.
  final ValueNotifier<Offset> cursor = ValueNotifier(Offset.zero);

  /// Los movimientos se agrupan para no saturar el canal (~60 por segundo).
  static const Duration moveInterval = Duration(milliseconds: 16);
  Timer? _moveTimer;
  Offset? _pendingMove;

  bool get _canSend => phase == RdpPhase.connected && !_closed;

  Future<void> start(RdpConnectionRequest request) async {
    // Suscribirse antes de conectar para no perder los primeros eventos.
    _subscription = _client.events.listen(_onEvent);
    try {
      textureId = await _client.connect(request);
    } on RdpException catch (error) {
      _fail(error.message);
      return;
    }
    if (_closed) {
      await _client.disconnect();
      return;
    }
    notifyListeners();
  }

  Future<void> answerCertificate({required bool accept}) async {
    final request = pendingCertificate;
    if (request == null) return;
    pendingCertificate = null;
    notifyListeners();
    await _client.answerCertificate(request.requestId, accept: accept);
  }

  // ---- Ratón (coordenadas del escritorio remoto) ----

  void click(Offset point, {bool right = false}) {
    if (!_canSend) return;
    _flushMove();
    final button = right ? PointerFlags.rightButton : PointerFlags.leftButton;
    _pointer(point, PointerFlags.move);
    _pointer(point, PointerFlags.down | button);
    _pointer(point, button);
  }

  void pressLeft(Offset point) {
    if (!_canSend) return;
    _flushMove();
    _pointer(point, PointerFlags.move);
    _pointer(point, PointerFlags.down | PointerFlags.leftButton);
  }

  void moveTo(Offset point) {
    if (!_canSend) return;
    cursor.value = point;
    _pendingMove = point;
    _moveTimer ??= Timer(moveInterval, _flushMove);
  }

  void releaseLeft(Offset point) {
    if (!_canSend) return;
    _flushMove();
    _pointer(point, PointerFlags.leftButton);
  }

  /// Un paso de rueda: [towardsTop] desplaza el contenido hacia arriba.
  void scroll(Offset point, {required bool towardsTop, bool horizontal = false}) {
    if (!_canSend) return;
    _flushMove();
    _pointer(point, PointerFlags.wheelStep(positive: towardsTop, horizontal: horizontal));
  }

  void _flushMove() {
    _moveTimer?.cancel();
    _moveTimer = null;
    final point = _pendingMove;
    _pendingMove = null;
    if (point != null) _pointer(point, PointerFlags.move);
  }

  void _pointer(Offset point, int flags) {
    cursor.value = point;
    unawaited(_client.sendPointer(point.dx.round(), point.dy.round(), flags));
  }

  // ---- Teclado ----

  void toggleModifier(int virtualKey) {
    if (!activeModifiers.remove(virtualKey)) activeModifiers.add(virtualKey);
    notifyListeners();
  }

  /// Pulsa una tecla especial (VK), con los modificadores activos.
  void pressKey(int virtualKey) {
    if (!_canSend) return;
    _withModifiers(() {
      unawaited(_client.sendKey(virtualKey, down: true));
      unawaited(_client.sendKey(virtualKey, down: false));
    });
  }

  /// Texto del teclado del teléfono. Con modificadores activos, las letras y
  /// los dígitos se envían como teclas (Ctrl+C, Win+R…): Unicode no combina
  /// con Ctrl ni Alt.
  void typeText(String text) {
    if (!_canSend || text.isEmpty) return;
    if (activeModifiers.isEmpty) {
      unawaited(_client.sendText(text));
      return;
    }
    final virtualKey = VirtualKey.ofCharacter(text);
    if (virtualKey == null) {
      unawaited(_client.sendText(text));
      return;
    }
    pressKey(virtualKey);
  }

  void _withModifiers(void Function() action) {
    final modifiers = activeModifiers.toList();
    for (final key in modifiers) {
      unawaited(_client.sendKey(key, down: true));
    }
    action();
    for (final key in modifiers.reversed) {
      unawaited(_client.sendKey(key, down: false));
    }
    if (modifiers.isNotEmpty) {
      activeModifiers.clear();
      notifyListeners();
    }
  }

  /// Cierra la sesión nativa. Idempotente.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _moveTimer?.cancel();
    // No hace falta esperar a que termine la cancelación para desconectar.
    unawaited(_subscription?.cancel());
    _subscription = null;
    await _client.disconnect();
  }

  void _onEvent(RdpEvent event) {
    switch (event) {
      case RdpResized(:final width, :final height):
        if (desktopSize == null) cursor.value = Offset(width / 2, height / 2);
        desktopSize = (width: width, height: height);
      case RdpConnected():
        phase = RdpPhase.connected;
      case RdpFailed(:final message):
        _fail(message);
        return;
      case RdpDisconnected():
        phase = RdpPhase.closed;
      case final RdpCertificateRequest request:
        pendingCertificate = request;
    }
    notifyListeners();
  }

  void _fail(String nativeMessage) {
    phase = RdpPhase.failed;
    errorMessage = nativeMessage.isEmpty
        ? 'No se pudo conectar con el equipo.'
        : 'No se pudo conectar con el equipo ($nativeMessage).';
    pendingCertificate = null;
    notifyListeners();
  }

  @override
  void dispose() {
    unawaited(close());
    cursor.dispose();
    super.dispose();
  }
}
