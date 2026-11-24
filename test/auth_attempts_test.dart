import 'package:arreglaya/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  Future<void> fillLogin(
    WidgetTester tester,
    Future<void> Function(String, String) signIn,
  ) async {
    await tester.pumpWidget(MaterialApp(home: AuthScreen(signIn: signIn)));
    await tester.enterText(
      find.byType(TextFormField).at(0),
      'cliente@example.com',
    );
    await tester.enterText(find.byType(TextFormField).at(1), 'incorrecta');
  }

  Future<void> submit(WidgetTester tester) async {
    await tester.tap(find.byType(FilledButton));
    await tester.pumpAndSettle();
  }

  testWidgets(
    'bloquea solo al tercer error y permite reintentar a los 30 segundos',
    (tester) async {
      var calls = 0;
      await fillLogin(tester, (_, _) async {
        calls++;
        throw const AuthException(
          'Invalid login credentials',
          code: 'invalid_credentials',
        );
      });
      for (var attempt = 1; attempt <= 2; attempt++) {
        await submit(tester);
        expect(
          tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
          isNotNull,
        );
        expect(
          find.text(
            'Correo o contraseña incorrectos. Intentos restantes: ${3 - attempt}.',
          ),
          findsOneWidget,
        );
      }
      await submit(tester);
      expect(calls, 3);
      expect(
        tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNull,
      );
      await tester.pump(const Duration(seconds: 29));
      expect(
        tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNull,
      );
      await tester.pump(const Duration(seconds: 1));
      expect(
        tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNotNull,
      );
      await submit(tester);
      expect(calls, 4);
      expect(
        find.text('Correo o contraseña incorrectos. Intentos restantes: 2.'),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'conexión y límite de correos no cuentan como contraseña incorrecta',
    (tester) async {
      var calls = 0;
      await fillLogin(tester, (_, _) async {
        calls++;
        if (calls == 1) throw Exception('offline');
        if (calls == 2) {
          throw const AuthException(
            'Email rate limit exceeded',
            code: 'over_email_send_rate_limit',
          );
        }
        throw const AuthException(
          'Invalid login credentials',
          code: 'invalid_credentials',
        );
      });
      await submit(tester);
      await submit(tester);
      await submit(tester);
      expect(
        find.text('Correo o contraseña incorrectos. Intentos restantes: 2.'),
        findsOneWidget,
      );
      expect(
        tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNotNull,
      );
    },
  );
}
