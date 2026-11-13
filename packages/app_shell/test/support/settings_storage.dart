import 'package:flutter_test/flutter_test.dart';
import 'package:hydrated_bloc/hydrated_bloc.dart';
import 'package:mocktail/mocktail.dart';

class _MockStorage extends Mock implements Storage {}

/// Gives the app-level settings controllers the hydrated storage they need,
/// holding nothing, for a test that opens Settings. Restored at the test's
/// end.
void useSettingsStorage() {
  final storage = _MockStorage();
  when(() => storage.read(any())).thenReturn(null);
  when(() => storage.write(any(), any<dynamic>())).thenAnswer((_) async {});
  HydratedBloc.storage = storage;
  addTearDown(() => HydratedBloc.storage = null);
}
