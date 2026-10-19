import 'dart:ui';

import 'package:altair_wake/features/remote_desktop/data/rdp_client.dart';
import 'package:altair_wake/features/remote_desktop/domain/monitor_layout.dart';
import 'package:altair_wake/features/remote_desktop/domain/rdp_input.dart';
import 'package:altair_wake/features/remote_desktop/domain/rdp_viewport.dart';
import 'package:altair_wake/features/remote_desktop/presentation/rdp_session_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fakes.dart';

const request = RdpConnectionRequest(
  host: '192.168.100.20',
  port: 3389,
  username: 'usuario',
  password: '',
  width: 1920,
  height: 1080,
);

void main() {
  group('PointerFlags.wheelStep', () {
    test('hacia arriba: rueda con +120', () {
      expect(PointerFlags.wheelStep(positive: true), 0x0278);
    });

    test('hacia abajo: bandera negativa y -120 en complemento a dos', () {
      expect(PointerFlags.wheelStep(positive: false), 0x0388);
    });

    test('horizontal usa la rueda horizontal', () {
      expect(PointerFlags.wheelStep(positive: true, horizontal: true), 0x0478);
    });
  });

  group('VirtualKey', () {
    test('flechas, Inicio, Fin, Supr y Win llevan la marca de tecla extendida', () {
      for (final key in [
        VirtualKey.left,
        VirtualKey.up,
        VirtualKey.right,
        VirtualKey.down,
        VirtualKey.home,
        VirtualKey.end,
        VirtualKey.delete,
        VirtualKey.pageUp,
        VirtualKey.pageDown,
        VirtualKey.windows,
      ]) {
        expect(key & VirtualKey.extended, VirtualKey.extended, reason: '0x${key.toRadixString(16)}');
      }
      expect(VirtualKey.left & 0xFF, 0x25);
      expect(VirtualKey.windows & 0xFF, 0x5B);
    });

    test('las teclas del bloque principal no son extendidas', () {
      for (final key in [VirtualKey.enter, VirtualKey.backspace, VirtualKey.escape, VirtualKey.control]) {
        expect(key & VirtualKey.extended, 0);
      }
    });
  });

  group('VirtualKey.ofCharacter', () {
    test('letras y dígitos tienen VK; el resto no', () {
      expect(VirtualKey.ofCharacter('c'), 0x43);
      expect(VirtualKey.ofCharacter('7'), 0x37);
      expect(VirtualKey.ofCharacter('ñ'), isNull);
      expect(VirtualKey.ofCharacter('ab'), isNull);
    });
  });

  group('MonitorLayout', () {
    test('interpreta y coloca los monitores de izquierda a derecha', () {
      final layout = MonitorLayout.tryParse('1920x1080, 1920X1080 ,1152x720')!;
      expect(layout.monitors, hasLength(3));
      expect(layout.bounds, const Size(4992, 1080));
      expect(layout.toFlatList(), [0, 0, 1920, 1080, 1920, 0, 1920, 1080, 3840, 0, 1152, 720]);
      expect(layout.format(), '1920x1080, 1920x1080, 1152x720');
    });

    test('una resolución suelta y el monitor principal', () {
      expect(MonitorLayout.tryParseResolution(' 1152 x 720 '), const Size(1152, 720));
      expect(MonitorLayout.tryParseResolution('100x720'), isNull);
      expect(MonitorLayout.formatResolution(const Size(1152, 720)), '1152x720');
      final primary = MonitorLayout.tryParse('2560x1440, 1920x1080')!.primaryOnly;
      expect(primary.monitors, [const Size(2560, 1440)]);
    });

    test('rechaza texto vacío o mal formado', () {
      expect(MonitorLayout.tryParse(''), isNull);
      expect(MonitorLayout.tryParse('1920 por 1080'), isNull);
      expect(MonitorLayout.tryParse('1920x1080,'), isNull);
      expect(MonitorLayout.tryParse('10x10'), isNull);
    });
  });

  group('RdpViewport', () {
    test('al inicio muestra todo el escritorio centrado', () {
      final viewport = RdpViewport(const Size(4000, 1000))..resize(const Size(400, 800));
      expect(viewport.scale, 0.1);
      expect(viewport.origin, const Offset(0, 350));
      expect(viewport.toDesktop(const Offset(200, 400)), const Offset(2000, 500));
    });

    test('el zoom conserva el punto bajo los dedos y se limita', () {
      final viewport = RdpViewport(const Size(4000, 1000))..resize(const Size(400, 800));
      final before = viewport.toDesktop(const Offset(100, 400));
      viewport.zoomAt(const Offset(100, 400), 2);
      expect(viewport.toDesktop(const Offset(100, 400)).dx, closeTo(before.dx, 0.01));
      viewport.zoomAt(Offset.zero, 1000);
      expect(viewport.scale, viewport.fitScale * RdpViewport.maxZoom);
      viewport.zoomAt(Offset.zero, 0.0001);
      expect(viewport.scale, viewport.fitScale);
    });

    test('focus encaja un monitor y ni el desplazamiento ni el zoom salen de él', () {
      final viewport = RdpViewport(const Size(4000, 1000))..resize(const Size(400, 200));
      viewport.focus(const Rect.fromLTWH(2000, 0, 2000, 1000));
      expect(viewport.scale, 0.2);
      expect(viewport.toDesktop(Offset.zero), const Offset(2000, 0));
      viewport.panBy(const Offset(10000, 0));
      expect(viewport.toDesktop(Offset.zero), const Offset(2000, 0));
      viewport.zoomAt(Offset.zero, 0.01);
      expect(viewport.scale, 0.2);
    });

    test('el monitor encuadrado se conserva al girar el teléfono', () {
      final viewport = RdpViewport(const Size(3840, 1080))..resize(const Size(400, 800));
      const second = Rect.fromLTWH(1920, 0, 1920, 1080);
      viewport.focus(second);
      expect(viewport.zoomedIn, isFalse);
      viewport.resize(const Size(800, 400));
      expect(viewport.focusArea, second);
      expect(viewport.toScreenRect(second).width, closeTo(711.1, 0.1));
      expect(viewport.toVisibleDesktop(Offset.zero).dx, 1920);
      viewport.showAll();
      expect(viewport.focusArea, isNull);
    });

    test('reveal desplaza la vista solo si el punto queda cerca del borde', () {
      final viewport = RdpViewport(const Size(1000, 500))..resize(const Size(100, 100));
      viewport.zoomAt(Offset.zero, 8);
      final before = viewport.origin;
      expect(viewport.reveal(viewport.toDesktop(const Offset(50, 50))), isFalse);
      expect(viewport.origin, before);
      expect(viewport.reveal(const Offset(900, 250), margin: 10), isTrue);
      expect(viewport.toScreen(const Offset(900, 250)).dx, closeTo(90, 0.01));
    });

    test('las coordenadas fuera del escritorio se recortan', () {
      final viewport = RdpViewport(const Size(1000, 500))..resize(const Size(1000, 1000));
      expect(viewport.toDesktop(const Offset(-50, 0)), const Offset(0, 0));
      expect(viewport.toDesktop(const Offset(5000, 5000)), const Offset(999, 499));
    });
  });

  group('RdpSessionController (entrada)', () {
    Future<(FakeRdpClient, RdpSessionController)> connected() async {
      final client = FakeRdpClient();
      final controller = RdpSessionController(client);
      await controller.start(request);
      client.eventController
        ..add(const RdpResized(1920, 1080))
        ..add(const RdpConnected());
      await pumpEventQueue();
      return (client, controller);
    }

    test('un clic mueve, pulsa y suelta en el punto', () async {
      final (client, controller) = await connected();
      controller.click(const Offset(10.4, 20.6));
      expect(client.pointerEvents, [
        (10, 21, PointerFlags.move),
        (10, 21, PointerFlags.down | PointerFlags.leftButton),
        (10, 21, PointerFlags.leftButton),
      ]);
    });

    test('el puntero empieza en el centro y sigue al último evento', () async {
      final (_, controller) = await connected();
      expect(controller.cursor.value, const Offset(960, 540));
      controller.moveTo(const Offset(5, 6));
      expect(controller.cursor.value, const Offset(5, 6));
      controller.click(const Offset(7, 8));
      expect(controller.cursor.value, const Offset(7, 8));
    });

    test('el clic derecho usa el botón 2', () async {
      final (client, controller) = await connected();
      controller.click(Offset.zero, right: true);
      expect(client.pointerEvents[1].$3, PointerFlags.down | PointerFlags.rightButton);
    });

    test('los movimientos de arrastre se agrupan', () async {
      final (client, controller) = await connected();
      controller.pressLeft(Offset.zero);
      for (var i = 1; i <= 10; i++) {
        controller.moveTo(Offset(i.toDouble(), 0));
      }
      await Future<void>.delayed(RdpSessionController.moveInterval * 3);
      controller.releaseLeft(const Offset(10, 0));

      final moves = client.pointerEvents
          .where((event) => event.$3 == PointerFlags.move)
          .toList();
      // Uno al pulsar y uno por el lote de 10 movimientos.
      expect(moves, [(0, 0, PointerFlags.move), (10, 0, PointerFlags.move)]);
      expect(client.pointerEvents.last, (10, 0, PointerFlags.leftButton));
    });

    test('Ctrl + letra se envía como teclas y el modificador se libera', () async {
      final (client, controller) = await connected();
      controller.toggleModifier(VirtualKey.control);
      controller.typeText('c');
      expect(client.texts, isEmpty);
      expect(client.keyEvents, [
        (VirtualKey.control, true),
        (0x43, true),
        (0x43, false),
        (VirtualKey.control, false),
      ]);
      expect(controller.activeModifiers, isEmpty);
    });

    test('sin modificadores el texto viaja como Unicode', () async {
      final (client, controller) = await connected();
      controller.typeText('ñ');
      expect(client.texts, ['ñ']);
      expect(client.keyEvents, isEmpty);
    });

    test('antes de conectar no se envía entrada', () async {
      final client = FakeRdpClient();
      final controller = RdpSessionController(client);
      await controller.start(request);
      controller
        ..click(Offset.zero)
        ..pressKey(VirtualKey.enter)
        ..typeText('a');
      expect(client.pointerEvents, isEmpty);
      expect(client.keyEvents, isEmpty);
      expect(client.texts, isEmpty);
    });
  });
}
