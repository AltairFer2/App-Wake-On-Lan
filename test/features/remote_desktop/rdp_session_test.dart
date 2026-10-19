import 'package:altair_wake/features/remote_desktop/data/rdp_client.dart';
import 'package:altair_wake/features/remote_desktop/domain/remote_desktop.dart';
import 'package:altair_wake/features/remote_desktop/presentation/rdp_session_controller.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fakes.dart';

const request = RdpConnectionRequest(
  host: '192.168.100.20',
  port: 3389,
  username: 'usuario',
  password: '',
  width: 1920,
  height: 900,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('remoteDesktopSizeFor', () {
    test('horizontal, limitado a 1920 de ancho y en múltiplos de 4', () {
      // Pantalla vertical 1080 x 2280 px.
      expect(remoteDesktopSizeFor(1080, 2280), (width: 1920, height: 908));
    });

    test('una pantalla pequeña conserva su tamaño', () {
      expect(remoteDesktopSizeFor(1280, 720), (width: 1280, height: 720));
    });
  });

  group('RdpEvent.fromMap', () {
    test('interpreta cada tipo de evento', () {
      expect(
        RdpEvent.fromMap({'type': 'resize', 'width': 1920, 'height': 908}),
        isA<RdpResized>().having((e) => e.width, 'width', 1920),
      );
      expect(RdpEvent.fromMap({'type': 'connected'}), isA<RdpConnected>());
      expect(
        RdpEvent.fromMap({'type': 'failed', 'message': 'logon failed'}),
        isA<RdpFailed>().having((e) => e.message, 'message', 'logon failed'),
      );
      expect(RdpEvent.fromMap({'type': 'disconnected'}), isA<RdpDisconnected>());
      expect(
        RdpEvent.fromMap({
          'type': 'certificate',
          'requestId': 3,
          'host': '192.168.100.20',
          'port': 3389,
          'fingerprint': 'sha256:aa',
          'changed': true,
          'oldFingerprint': 'sha256:bb',
        }),
        isA<RdpCertificateRequest>()
            .having((e) => e.changed, 'changed', true)
            .having((e) => e.previousFingerprint, 'anterior', 'sha256:bb'),
      );
    });

    test('un tipo desconocido se ignora', () {
      expect(RdpEvent.fromMap({'type': 'futuro'}), isNull);
    });
  });

  group('RdpClient', () {
    const channel = MethodChannel('prueba/rdp');
    const client = RdpClient(methods: channel);
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    tearDown(() => messenger.setMockMethodCallHandler(channel, null));

    test('connect envía la petición y devuelve la textura', () async {
      MethodCall? received;
      messenger.setMockMethodCallHandler(channel, (call) async {
        received = call;
        return 42;
      });
      expect(await client.connect(request), 42);
      expect(received?.arguments, request.toMap());
    });

    test('un error nativo se convierte en RdpException', () async {
      messenger.setMockMethodCallHandler(
        channel,
        (_) async => throw PlatformException(code: 'busy', message: 'ocupado'),
      );
      expect(
        client.connect(request),
        throwsA(isA<RdpException>().having((e) => e.code, 'code', 'busy')),
      );
    });

    test('sin implementación nativa no está soportado', () async {
      expect(await client.isSupported(), isFalse);
    });
  });

  group('RdpSessionController', () {
    test('conecta, recibe tamaño y queda conectado', () async {
      final client = FakeRdpClient();
      final controller = RdpSessionController(client);
      await controller.start(request);
      client.eventController
        ..add(const RdpResized(1920, 908))
        ..add(const RdpConnected());
      await pumpEventQueue();

      expect(client.connections.single.host, '192.168.100.20');
      expect(controller.textureId, 7);
      expect(controller.desktopSize, (width: 1920, height: 908));
      expect(controller.phase, RdpPhase.connected);
    });

    test('un fallo nativo deja la sesión fallida con el motivo', () async {
      final client = FakeRdpClient();
      final controller = RdpSessionController(client);
      await controller.start(request);
      client.eventController.add(const RdpFailed('ERRCONNECT_LOGON_FAILURE'));
      await pumpEventQueue();

      expect(controller.phase, RdpPhase.failed);
      expect(controller.errorMessage, contains('ERRCONNECT_LOGON_FAILURE'));
    });

    test('si no puede arrancar informa el error', () async {
      final client = FakeRdpClient(
        connectError: const RdpException('unsupported', ''),
      );
      final controller = RdpSessionController(client);
      await controller.start(request);
      expect(controller.phase, RdpPhase.failed);
      expect(controller.errorMessage, 'No se pudo conectar con el equipo.');
    });

    test('responde al certificado y lo retira de pendientes', () async {
      final client = FakeRdpClient();
      final controller = RdpSessionController(client);
      await controller.start(request);
      client.eventController.add(
        const RdpCertificateRequest(
          requestId: 5,
          host: '192.168.100.20',
          port: 3389,
          subject: 'CN=PC',
          issuer: 'CN=PC',
          fingerprint: 'sha256:aa',
          changed: false,
        ),
      );
      await pumpEventQueue();
      expect(controller.pendingCertificate?.requestId, 5);

      await controller.answerCertificate(accept: true);
      expect(client.certificateAnswers, [(5, true)]);
      expect(controller.pendingCertificate, isNull);
    });

    test('close desconecta una sola vez', () async {
      final client = FakeRdpClient();
      final controller = RdpSessionController(client);
      await controller.start(request);
      await controller.close();
      await controller.close();
      expect(client.disconnects, 1);
    });
  });
}
