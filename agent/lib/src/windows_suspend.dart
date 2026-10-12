import 'dart:ffi';

import 'package:ffi/ffi.dart';

import 'power_actions.dart';

const int _tokenAdjustPrivileges = 0x0020;
const int _tokenQuery = 0x0008;
const int _sePrivilegeEnabled = 0x00000002;

final class _Luid extends Struct {
  @Uint32()
  external int lowPart;

  @Int32()
  external int highPart;
}

/// `TOKEN_PRIVILEGES` con un único `LUID_AND_ATTRIBUTES`.
final class _TokenPrivileges extends Struct {
  @Uint32()
  external int privilegeCount;

  external _Luid luid;

  @Uint32()
  external int attributes;
}

final DynamicLibrary _kernel32 = DynamicLibrary.open('kernel32.dll');
final DynamicLibrary _advapi32 = DynamicLibrary.open('advapi32.dll');
final DynamicLibrary _powrprof = DynamicLibrary.open('powrprof.dll');

final _getCurrentProcess = _kernel32
    .lookupFunction<IntPtr Function(), int Function()>('GetCurrentProcess');
final _closeHandle = _kernel32
    .lookupFunction<Int32 Function(IntPtr), int Function(int)>('CloseHandle');
final _openProcessToken = _advapi32.lookupFunction<
    Int32 Function(IntPtr, Uint32, Pointer<IntPtr>),
    int Function(int, int, Pointer<IntPtr>)>('OpenProcessToken');
final _lookupPrivilegeValue = _advapi32.lookupFunction<
    Int32 Function(Pointer<Utf16>, Pointer<Utf16>, Pointer<_Luid>),
    int Function(Pointer<Utf16>, Pointer<Utf16>, Pointer<_Luid>)>(
  'LookupPrivilegeValueW',
);
final _adjustTokenPrivileges = _advapi32.lookupFunction<
    Int32 Function(
      IntPtr,
      Int32,
      Pointer<_TokenPrivileges>,
      Uint32,
      Pointer<_TokenPrivileges>,
      Pointer<Uint32>,
    ),
    int Function(
      int,
      int,
      Pointer<_TokenPrivileges>,
      int,
      Pointer<_TokenPrivileges>,
      Pointer<Uint32>,
    )>('AdjustTokenPrivileges');
final _setSuspendState = _powrprof.lookupFunction<
    Uint8 Function(Uint8, Uint8, Uint8),
    int Function(int, int, int)>('SetSuspendState');

/// Suspende el equipo a RAM (S3) dejando habilitados los eventos de
/// activación, imprescindibles para Wake-on-LAN.
///
/// `SetSuspendState` exige `SeShutdownPrivilege` habilitado en el token; el
/// privilegio existe para SYSTEM pero está deshabilitado por defecto.
void suspendToRam() {
  _enableShutdownPrivilege();
  const hibernate = 0;
  const force = 0;
  const wakeEventsDisabled = 0;
  if (_setSuspendState(hibernate, force, wakeEventsDisabled) == 0) {
    throw const PowerActionException('SetSuspendState falló.');
  }
}

void _enableShutdownPrivilege() {
  using((arena) {
    final token = arena<IntPtr>();
    if (_openProcessToken(
          _getCurrentProcess(),
          _tokenAdjustPrivileges | _tokenQuery,
          token,
        ) ==
        0) {
      throw const PowerActionException('OpenProcessToken falló.');
    }
    try {
      final luid = arena<_Luid>();
      final name = 'SeShutdownPrivilege'.toNativeUtf16(allocator: arena);
      if (_lookupPrivilegeValue(nullptr, name, luid) == 0) {
        throw const PowerActionException('LookupPrivilegeValueW falló.');
      }
      final privileges = arena<_TokenPrivileges>();
      privileges.ref
        ..privilegeCount = 1
        ..attributes = _sePrivilegeEnabled;
      privileges.ref.luid
        ..lowPart = luid.ref.lowPart
        ..highPart = luid.ref.highPart;
      if (_adjustTokenPrivileges(
            token.value,
            0,
            privileges,
            0,
            nullptr,
            nullptr,
          ) ==
          0) {
        throw const PowerActionException('AdjustTokenPrivileges falló.');
      }
    } finally {
      _closeHandle(token.value);
    }
  });
}
