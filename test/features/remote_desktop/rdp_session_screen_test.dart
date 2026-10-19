import 'package:altair_wake/features/remote_desktop/data/rdp_client.dart';
import 'package:altair_wake/features/remote_desktop/domain/rdp_input.dart';
import 'package:altair_wake/features/remote_desktop/presentation/rdp_session_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fakes.dart';

/// Escritorio cuadrado para que la escala sea fácil de calcular.
const _desktop = 1000;

void main() {
  late FakeRdpClient client;

  Future<void> openSession(WidgetTester tester) async {
    tester.view
      ..physicalSize = const Size(800, 1200)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    client = FakeRdpClient();
    await tester.pumpWidget(
      MaterialApp(
        home: RdpSessionScreen(
          client: client,
          title: 'PC',
          host: '192.168.100.20',
          port: 3389,
          username: 'usuario',
          password: '',
        ),
      ),
    );
    await tester.pump();
    client.eventController
      ..add(const RdpResized(_desktop, _desktop))
      ..add(const RdpConnected());
    await tester.pump();
    await tester.pump();
  }

  Rect desktopArea(WidgetTester tester) => tester.getRect(find.byType(Texture));

  List<int> flags() => [for (final event in client.pointerEvents) event.$3];

  Future<void> selectMode(WidgetTester tester, RdpControlMode mode) async {
    await tester.tap(find.byTooltip('Modo de control'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(CheckedPopupMenuItem<RdpControlMode>, mode.label));
    await tester.pumpAndSettle();
  }

  testWidgets('modo puntero: tocar hace clic donde está el puntero', (tester) async {
    await openSession(tester);
    await tester.tapAt(desktopArea(tester).topLeft + const Offset(10, 10));
    await tester.pump(const Duration(milliseconds: 600));

    expect(flags(), contains(PointerFlags.down | PointerFlags.leftButton));
    // El puntero arranca en el centro del escritorio, no bajo el dedo.
    expect(client.pointerEvents.first.$1, _desktop ~/ 2);
    expect(client.pointerEvents.first.$2, _desktop ~/ 2);
  });

  testWidgets('modo puntero: arrastrar mueve el puntero sin pulsar', (tester) async {
    await openSession(tester);
    final area = desktopArea(tester);
    final scale = area.width / _desktop;
    await tester.dragFrom(area.center, const Offset(100, 0));
    await tester.pump(const Duration(milliseconds: 50));

    expect(flags(), isNot(contains(PointerFlags.down | PointerFlags.leftButton)));
    final last = client.pointerEvents.last;
    expect(last.$3, PointerFlags.move);
    // Recorre en pantalla lo mismo que el dedo (salvo la tolerancia inicial).
    expect(last.$1, greaterThan(_desktop ~/ 2 + 50 ~/ scale));
  });

  testWidgets('mantener sin mover hace clic derecho', (tester) async {
    await openSession(tester);
    await tester.longPressAt(desktopArea(tester).center);
    await tester.pump();

    expect(flags(), contains(PointerFlags.down | PointerFlags.rightButton));
    expect(flags(), isNot(contains(PointerFlags.down | PointerFlags.leftButton)));
  });

  testWidgets('mantener y mover arrastra con el botón izquierdo', (tester) async {
    await openSession(tester);
    final gesture = await tester.startGesture(desktopArea(tester).center);
    await tester.pump(const Duration(milliseconds: 600));
    await gesture.moveBy(const Offset(60, 0));
    await tester.pump(const Duration(milliseconds: 50));
    await gesture.up();
    await tester.pump();

    expect(flags(), contains(PointerFlags.down | PointerFlags.leftButton));
    expect(flags().last, PointerFlags.leftButton);
    expect(flags(), isNot(contains(PointerFlags.down | PointerFlags.rightButton)));
  });

  testWidgets('toque directo: el clic va bajo el dedo', (tester) async {
    await openSession(tester);
    await selectMode(tester, RdpControlMode.touch);
    final area = desktopArea(tester);
    await tester.tapAt(area.topLeft + Offset(area.width / 4, area.height / 4));
    await tester.pump(const Duration(milliseconds: 600));

    final click = client.pointerEvents.firstWhere(
      (event) => event.$3 == (PointerFlags.down | PointerFlags.leftButton),
    );
    expect(click.$1, closeTo(_desktop / 4, 2));
    expect(click.$2, closeTo(_desktop / 4, 2));
  });

  testWidgets('mover la vista no envía nada al PC', (tester) async {
    await openSession(tester);
    await selectMode(tester, RdpControlMode.view);
    await tester.tapAt(desktopArea(tester).center);
    await tester.dragFrom(desktopArea(tester).center, const Offset(80, 0));
    await tester.pump(const Duration(milliseconds: 600));
    expect(client.pointerEvents, isEmpty);
  });

  testWidgets('el teclado del teléfono envía solo lo que cambia', (tester) async {
    await openSession(tester);
    final field = find.byType(TextField);
    const sentinel = '​';

    await tester.enterText(field, '${sentinel}hola');
    await tester.enterText(field, '${sentinel}hol');
    await tester.enterText(field, '${sentinel}hola\n');
    await tester.pump();

    expect(client.texts, ['h', 'o', 'l', 'a', 'a']);
    expect(client.keyEvents, [
      (VirtualKey.backspace, true),
      (VirtualKey.backspace, false),
      (VirtualKey.enter, true),
      (VirtualKey.enter, false),
    ]);
    // Tras Enter el campo se vacía para la siguiente línea.
    expect(tester.widget<TextField>(field).controller!.text, sentinel);
  });

  testWidgets('borrar con el campo vacío envía un retroceso', (tester) async {
    await openSession(tester);
    final field = find.byType(TextField);
    await tester.enterText(field, '');
    await tester.enterText(field, '');
    await tester.pump();
    expect(client.keyEvents.where((event) => event.$2), hasLength(2));
    expect(client.keyEvents.first, (VirtualKey.backspace, true));
  });

  testWidgets('la sesión se abre en horizontal y restaura al salir', (tester) async {
    final calls = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        calls.add(call.method);
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await openSession(tester);
    expect(calls, contains('SystemChrome.setPreferredOrientations'));
    expect(calls, contains('SystemChrome.setEnabledSystemUIMode'));

    calls.clear();
    await tester.pumpWidget(const SizedBox());
    expect(calls, contains('SystemChrome.setPreferredOrientations'));
  });

  testWidgets('las flechas de la barra se envían como teclas extendidas', (tester) async {
    await openSession(tester);
    await tester.tap(find.text('←'));
    await tester.pump();
    expect(client.keyEvents, [(VirtualKey.left, true), (VirtualKey.left, false)]);
  });
}
