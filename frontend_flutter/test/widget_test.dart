// Replaces `flutter create .`'s stock counter-app test, which references a
// `MyApp` class that doesn't exist in this codebase (the real entry point
// is `DcovApp`, requiring an `AppState`) - caught by a real `flutter
// analyze` run as a creation_with_non_type error. This is a minimal smoke
// test: it confirms the app builds a widget tree without throwing, not a
// substitute for matching_test.dart's real coverage of the matching engine.
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:dcov_field/main.dart';
import 'package:dcov_field/services/app_state.dart';
import 'package:dcov_field/services/local_store.dart';

void main() {
  testWidgets('DcovApp builds without throwing', (WidgetTester tester) async {
    // In-memory plugin backends: no platform channel exists under
    // `flutter test`, so the real ones throw MissingPluginException.
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    final store = await LocalStore.open();
    final app = AppState(store);
    // Deliberately not awaiting app.boot() here - this test only checks
    // that the widget tree constructs and the initial (booting) frame
    // renders, not the full async boot sequence (catalogue load, session
    // restore), which belongs in its own test with a mocked backend.
    await tester.pumpWidget(DcovApp(app: app));
    expect(find.byType(DcovApp), findsOneWidget);
  });
}
