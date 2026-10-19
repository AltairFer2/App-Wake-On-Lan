import 'package:altair_wake/features/devices/domain/device.dart';
import 'package:altair_wake/features/remote_desktop/data/remote_desktop_launcher.dart';
import 'package:altair_wake/features/remote_desktop/domain/remote_desktop.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('remoteDesktopHostOf', () {
    test('usa la IPv4 local cuando hay puerto RDP', () {
      expect(
        remoteDesktopHostOf(sampleDevice(remoteDesktopPort: 3389)),
        '192.168.100.20',
      );
    });

    test('sin puerto RDP no hay escritorio remoto', () {
      expect(remoteDesktopHostOf(sampleDevice()), isNull);
    });

    test('sin IPv4 local (o con una IPv6) no hay escritorio remoto', () {
      expect(
        remoteDesktopHostOf(sampleDevice(localIpv4: null, remoteDesktopPort: 3389)),
        isNull,
      );
      expect(
        remoteDesktopHostOf(sampleDevice(localIpv4: '::1', remoteDesktopPort: 3389)),
        isNull,
      );
    });
  });

  test('enlace con el formato del cliente de Microsoft', () {
    expect(
      remoteDesktopLink('192.168.100.20', 3389),
      'rdp://full%20address=s:192.168.100.20:3389',
    );
  });

  group('persistencia del puerto RDP', () {
    test('se conserva al guardar y leer', () {
      final device = sampleDevice(remoteDesktopPort: 3390);
      expect(Device.fromJson(device.toJson()).remoteDesktopPort, 3390);
    });

    test('datos guardados antes de esta función se leen sin escritorio', () {
      final json = sampleDevice().toJson()..remove('remoteDesktopPort');
      expect(Device.fromJson(json).remoteDesktopPort, isNull);
    });

    test('un puerto fuera de rango invalida el registro', () {
      final json = sampleDevice().toJson()..['remoteDesktopPort'] = 70000;
      expect(() => Device.fromJson(json), throwsFormatException);
    });
  });

  group('RemoteDesktopLauncher', () {
    const channel = MethodChannel('prueba/remote_desktop');
    const launcher = RemoteDesktopLauncher(channel);
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    tearDown(() => messenger.setMockMethodCallHandler(channel, null));

    test('envía el enlace y el paquete, e interpreta la respuesta', () async {
      MethodCall? received;
      messenger.setMockMethodCallHandler(channel, (call) async {
        received = call;
        return 'clientApp';
      });

      final result = await launcher.open('192.168.100.20', 3389);

      expect(result, RemoteDesktopLaunch.clientApp);
      expect(received?.method, 'open');
      expect(received?.arguments, {
        'link': 'rdp://full%20address=s:192.168.100.20:3389',
        'package': windowsAppPackage,
      });
    });

    test('un error nativo o una respuesta desconocida es "no disponible"', () async {
      messenger.setMockMethodCallHandler(
        channel,
        (_) async => throw PlatformException(code: 'fallo'),
      );
      expect(
        await launcher.open('192.168.100.20', 3389),
        RemoteDesktopLaunch.unavailable,
      );

      messenger.setMockMethodCallHandler(channel, (_) async => 'otra cosa');
      expect(
        await launcher.open('192.168.100.20', 3389),
        RemoteDesktopLaunch.unavailable,
      );
    });

    test('sin implementación nativa es "no disponible"', () async {
      expect(
        await launcher.open('192.168.100.20', 3389),
        RemoteDesktopLaunch.unavailable,
      );
    });
  });
}
