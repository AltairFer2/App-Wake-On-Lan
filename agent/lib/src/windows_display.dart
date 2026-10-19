import 'dart:async';
import 'dart:ffi';

import 'package:ffi/ffi.dart';

import 'kernel32.dart';
import 'power_actions.dart';

const int _powerRequestContextVersion = 0;
const int _powerRequestContextSimpleString = 0x1;
const int _powerRequestDisplayRequired = 0;
const int _powerRequestSystemRequired = 1;
const int _esSystemRequired = 0x00000001;
const int _esDisplayRequired = 0x00000002;
const int _invalidHandleValue = -1;

/// `REASON_CONTEXT` con la variante de texto simple. Los dos punteros finales
/// completan el tamaño de la unión (`Detailed`: HMODULE, 2×ULONG, LPWSTR*).
final class _ReasonContext extends Struct {
  @Uint32()
  external int version;

  @Uint32()
  external int flags;

  external Pointer<Utf16> simpleReasonString;

  external Pointer<Void> reserved1;

  external Pointer<Void> reserved2;
}

final _powerCreateRequest = kernel32.lookupFunction<
    IntPtr Function(Pointer<_ReasonContext>),
    int Function(Pointer<_ReasonContext>)>('PowerCreateRequest');
final _powerSetRequest = kernel32.lookupFunction<
    Int32 Function(IntPtr, Int32),
    int Function(int, int)>('PowerSetRequest');
final _powerClearRequest = kernel32.lookupFunction<
    Int32 Function(IntPtr, Int32),
    int Function(int, int)>('PowerClearRequest');
final _setThreadExecutionState = kernel32.lookupFunction<
    Uint32 Function(Uint32),
    int Function(int)>('SetThreadExecutionState');

/// Mantiene la pantalla encendida y el sistema despierto durante un plazo
/// renovable.
///
/// Tras un despertar por red, Windows deja la pantalla apagada y aplica el
/// temporizador desatendido (2 min). Microsoft indica que hacen falta a la vez
/// `PowerRequestDisplayRequired` y `PowerRequestSystemRequired` para que la
/// pantalla siga encendida y el sistema no vuelva a dormir.
class DisplayKeepAlive {
  int? _handle;
  Pointer<_ReasonContext>? _context;
  Pointer<Utf16>? _reason;
  Timer? _releaseTimer;

  bool get isActive => _handle != null;

  /// Activa (o renueva) la petición durante [duration].
  void hold(Duration duration) {
    _ensureRequest();
    // Sin ES_CONTINUOUS: reinicia una vez los temporizadores de inactividad de
    // pantalla y sistema, lo que vuelve a encender la pantalla.
    _setThreadExecutionState(_esSystemRequired | _esDisplayRequired);
    _releaseTimer?.cancel();
    _releaseTimer = Timer(duration, release);
  }

  /// Libera la petición; Windows vuelve a aplicar sus temporizadores normales.
  void release() {
    _releaseTimer?.cancel();
    _releaseTimer = null;
    final handle = _handle;
    if (handle != null) {
      _powerClearRequest(handle, _powerRequestDisplayRequired);
      _powerClearRequest(handle, _powerRequestSystemRequired);
      closeHandle(handle);
    }
    _handle = null;
    _freeReason();
  }

  void _ensureRequest() {
    if (_handle != null) return;
    final reason = 'Altair Wake: acceso remoto solicitado'.toNativeUtf16();
    final context = calloc<_ReasonContext>()
      ..ref.version = _powerRequestContextVersion
      ..ref.flags = _powerRequestContextSimpleString
      ..ref.simpleReasonString = reason;
    _reason = reason;
    _context = context;
    final handle = _powerCreateRequest(context);
    if (handle == _invalidHandleValue || handle == 0) {
      _freeReason();
      throw const PowerActionException('PowerCreateRequest falló.');
    }
    _handle = handle;
    if (_powerSetRequest(handle, _powerRequestSystemRequired) == 0 ||
        _powerSetRequest(handle, _powerRequestDisplayRequired) == 0) {
      release();
      throw const PowerActionException('PowerSetRequest falló.');
    }
  }

  void _freeReason() {
    final reason = _reason;
    final context = _context;
    if (reason != null) calloc.free(reason);
    if (context != null) calloc.free(context);
    _reason = null;
    _context = null;
  }
}
