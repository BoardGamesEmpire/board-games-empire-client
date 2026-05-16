import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:drift_storage/src/databases/meta_database.dart';
import 'package:drift_storage/src/repositories/device_preferences_repository_impl.dart';
import 'package:interfaces/repositories.dart';
import 'package:models/domain.dart';

void main() {
  late MetaDatabase database;
  late DevicePreferencesRepository repository;

  setUp(() {
    database = MetaDatabase.test(NativeDatabase.memory());
    repository = DevicePreferencesRepositoryImpl(database);
  });

  tearDown(() async => database.close());

  group('DevicePreferencesRepositoryImpl', () {
    group('get', () {
      test('returns defaults when no row exists', () async {
        final prefs = await repository.get();

        expect(prefs.maxMonitoredServers, 5);
        expect(prefs.backgroundingTimeoutDesktopSeconds, 900);
        expect(prefs.backgroundingTimeoutMobileSeconds, 300);
        expect(prefs.batteryAwareTransitions, isFalse);
      });
    });

    group('save and get', () {
      test('persists custom values', () async {
        await repository.save(
          const DevicePreferences(
            maxMonitoredServers: 3,
            backgroundingTimeoutDesktopSeconds: 1800,
            backgroundingTimeoutMobileSeconds: 120,
            batteryAwareTransitions: true,
          ),
        );

        final prefs = await repository.get();

        expect(prefs.maxMonitoredServers, 3);
        expect(prefs.backgroundingTimeoutDesktopSeconds, 1800);
        expect(prefs.backgroundingTimeoutMobileSeconds, 120);
        expect(prefs.batteryAwareTransitions, isTrue);
      });

      test('upserts on subsequent save', () async {
        await repository.save(const DevicePreferences(maxMonitoredServers: 3));
        await repository.save(const DevicePreferences(maxMonitoredServers: 7));

        final prefs = await repository.get();
        expect(prefs.maxMonitoredServers, 7);
      });
    });

    group('watch', () {
      test('emits defaults immediately when no row exists', () async {
        await expectLater(
          repository.watch().take(1),
          emits(const DevicePreferences()),
        );
      });

      test('emits updated preferences after save', () async {
        const updated = DevicePreferences(maxMonitoredServers: 2);

        // Subscribe-then-mutate: post-Pass-3c, Drift's .watch() emits
        // the current value on subscribe (no fake initial yield).
        // take(2).toList() listens synchronously; pumpEventQueue lets
        // Drift's initial emission land before we mutate.
        final futureEmissions = repository.watch().take(2).toList();

        await pumpEventQueue();

        await repository.save(updated);

        expect(
          await futureEmissions.timeout(const Duration(seconds: 5)),
          equals([
            const DevicePreferences(), // initial (no row → defaults)
            updated, // after save
          ]),
        );
      });
    });

    group('backgroundingTimeoutSeconds helper', () {
      test('returns desktop value for desktop', () {
        const prefs = DevicePreferences(
          backgroundingTimeoutDesktopSeconds: 600,
          backgroundingTimeoutMobileSeconds: 120,
        );
        expect(prefs.backgroundingTimeoutSeconds(isDesktop: true), 600);
      });

      test('returns mobile value for mobile', () {
        const prefs = DevicePreferences(
          backgroundingTimeoutDesktopSeconds: 600,
          backgroundingTimeoutMobileSeconds: 120,
        );
        expect(prefs.backgroundingTimeoutSeconds(isDesktop: false), 120);
      });
    });
  });
}
