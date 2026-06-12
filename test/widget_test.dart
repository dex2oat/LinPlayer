// This is a basic Flutter widget test.
//
// To perform an interaction with a widget in your test, use the WidgetTester
// utility in the flutter_test package. For example, you can send tap and scroll
// gestures. You can also use WidgetTester to find child widgets in the widget
// tree, read text, and verify that the values of widget properties are correct.

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:linplayer_mobile/app.dart';
import 'package:linplayer_mobile/core/providers/app_preferences.dart';

void main() {
  testWidgets('App renders smoke test', (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    await initializeAppPreferences();

    await tester.pumpWidget(const ProviderScope(child: LinPlayerApp()));

    expect(find.byType(LinPlayerApp), findsOneWidget);
  });
}
