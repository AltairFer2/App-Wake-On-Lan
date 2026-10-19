import 'package:altair_wake/features/remote_desktop/domain/monitor_layout.dart';
import 'package:altair_wake/features/remote_desktop/presentation/monitor_layout_field.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late List<MonitorLayout?> changes;

  Future<void> pumpField(WidgetTester tester, {MonitorLayout? initial}) async {
    changes = [];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: MonitorLayoutField(initial: initial, onChanged: changes.add),
          ),
        ),
      ),
    );
  }

  /// Abre el menú del primer monitor que muestra [current] y elige [option].
  Future<void> choose(WidgetTester tester, String current, String option) async {
    await tester.tap(find.text(current).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text(option).last);
    await tester.pumpAndSettle();
  }

  testWidgets('sin monitores guardados está en Auto', (tester) async {
    await pumpField(tester);
    expect(find.text('Monitor 1 (principal)'), findsNothing);
    expect(find.textContaining('pantalla del teléfono'), findsOneWidget);
  });

  testWidgets('elegir el número de monitores añade uno por resolución', (tester) async {
    await pumpField(tester);
    await tester.tap(find.text('3'));
    await tester.pumpAndSettle();

    expect(find.text('Monitor 1 (principal)'), findsOneWidget);
    expect(find.text('Monitor 3'), findsOneWidget);
    expect(changes.last?.format(), '1920x1080, 1920x1080, 1920x1080');

    await tester.tap(find.text('Auto'));
    await tester.pumpAndSettle();
    expect(changes.last, isNull);
  });

  testWidgets('cambiar la resolución de un monitor desde la lista', (tester) async {
    await pumpField(tester, initial: MonitorLayout.tryParse('1920x1080, 1920x1080'));
    await choose(tester, '1920x1080', '2560x1440');
    expect(changes.last?.format(), '2560x1440, 1920x1080');
  });

  testWidgets('"Otra…" acepta una resolución personalizada', (tester) async {
    await pumpField(tester, initial: MonitorLayout.tryParse('1920x1080'));
    await choose(tester, '1920x1080', 'Otra…');
    await tester.enterText(find.byType(TextFormField).last, '1152x720');
    await tester.tap(find.text('Aceptar'));
    await tester.pumpAndSettle();

    expect(changes.last?.format(), '1152x720');
    expect(find.text('1152x720'), findsOneWidget);
  });

  testWidgets('"Otra…" rechaza un formato inválido', (tester) async {
    await pumpField(tester, initial: MonitorLayout.tryParse('1920x1080'));
    await choose(tester, '1920x1080', 'Otra…');
    await tester.enterText(find.byType(TextFormField).last, '12x720');
    await tester.tap(find.text('Aceptar'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Formato'), findsOneWidget);
    expect(changes, isEmpty);
  });

  testWidgets('conserva una resolución guardada que no está en la lista', (tester) async {
    await pumpField(tester, initial: MonitorLayout.tryParse('1920x1080, 1920x1080, 1152x720'));
    expect(find.text('1152x720'), findsOneWidget);
    expect(find.text('Monitor 3'), findsOneWidget);
  });
}
