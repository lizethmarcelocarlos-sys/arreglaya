import 'package:arreglaya/main.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('muestra la pantalla de configuración sin credenciales', (tester) async {
    await tester.pumpWidget(const ArreglaYaApp(configured: false));

    expect(find.text('ArreglaYa está listo'), findsOneWidget);
  });
}
