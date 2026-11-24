import 'package:arreglaya/technician_contact_actions.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'muestra las tres acciones y las habilita con datos del técnico',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: TechnicianContactActions(
              phone: '70123456',
              workZone: 'Santa Cruz',
              name: 'Técnico de prueba',
            ),
          ),
        ),
      );

      expect(find.text('Llamar'), findsOneWidget);
      expect(find.text('WhatsApp'), findsOneWidget);
      expect(find.text('Cómo llegar'), findsOneWidget);
      expect(
        tester
            .widget<OutlinedButton>(
              find.widgetWithText(OutlinedButton, 'Llamar'),
            )
            .onPressed,
        isNotNull,
      );
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, 'WhatsApp'))
            .onPressed,
        isNotNull,
      );
      expect(
        tester
            .widget<OutlinedButton>(
              find.widgetWithText(OutlinedButton, 'Cómo llegar'),
            )
            .onPressed,
        isNotNull,
      );
    },
  );

  testWidgets('no habilita llamada o WhatsApp sin teléfono', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: TechnicianContactActions(
            phone: null,
            workZone: 'Santa Cruz',
            name: 'Técnico de prueba',
          ),
        ),
      ),
    );

    expect(
      tester
          .widget<OutlinedButton>(find.widgetWithText(OutlinedButton, 'Llamar'))
          .onPressed,
      isNull,
    );
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, 'WhatsApp'))
          .onPressed,
      isNull,
    );
    expect(
      tester
          .widget<OutlinedButton>(
            find.widgetWithText(OutlinedButton, 'Cómo llegar'),
          )
          .onPressed,
      isNotNull,
    );
  });
}
