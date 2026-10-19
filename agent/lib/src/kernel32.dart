import 'dart:ffi';

/// Enlaces de kernel32.dll compartidos por las acciones de energía.
final DynamicLibrary kernel32 = DynamicLibrary.open('kernel32.dll');

final int Function() getCurrentProcess = kernel32
    .lookupFunction<IntPtr Function(), int Function()>('GetCurrentProcess');

final int Function(int handle) closeHandle = kernel32
    .lookupFunction<Int32 Function(IntPtr), int Function(int)>('CloseHandle');
