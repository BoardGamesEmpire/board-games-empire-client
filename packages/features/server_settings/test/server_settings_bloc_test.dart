import 'package:bge_test_support/access.dart';
import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';
import 'package:server_settings/server_settings.dart';

import 'support/fake_system_settings_remote.dart';

CallerAccess _update(AccessExtent extent) => CallerAccess.known({
  ResourceType.systemSetting: ResourceAccess(
    create: AccessExtent.none,
    read: AccessExtent.all,
    update: extent,
    delete: AccessExtent.none,
    manage: AccessExtent.none,
  ),
});

const _mailPatch = SystemSettingsPatch(smtpHost: SettingValue.set('smtp.x'));
const _signInPatch = SystemSettingsPatch(allowPasswordResets: false);

void main() {
  late FakeSystemSettingsRemote remote;
  late FakeCallerAccessRepository access;
  late ServerSettingsBloc bloc;

  final initial = settingsFixture();
  final saved = settingsFixture(smtpHost: 'smtp.x');

  setUp(() {
    remote = FakeSystemSettingsRemote();
    access = FakeCallerAccessRepository(_update(AccessExtent.all));
    bloc = ServerSettingsBloc(remote: remote, access: access);
  });

  tearDown(() async {
    await bloc.close();
    access.dispose();
  });

  Future<void> load() async {
    bloc.add(const ServerSettingsStarted());
    await pumpEventQueue();
    remote.fetches.last.complete(initial);
    await pumpEventQueue();
  }

  ServerSettingsLoaded loaded() => bloc.state as ServerSettingsLoaded;

  test('starts loading', () {
    expect(bloc.state, const ServerSettingsLoading());
  });

  test('a successful read loads revision 1 with update allowed', () async {
    await load();

    expect(
      bloc.state,
      ServerSettingsLoaded(
        settings: initial,
        mayUpdate: true,
        accessKnown: true,
        revision: 1,
      ),
    );
  });

  test('a refused read is denied and asks access again', () async {
    bloc.add(const ServerSettingsStarted());
    await pumpEventQueue();
    remote.fetches.single.completeError(
      const SystemSettingsForbiddenException('no', statusCode: 403),
    );
    await pumpEventQueue();

    expect(bloc.state, const ServerSettingsDenied());
    expect(access.refreshCount, 1);
  });

  test('a transient read fails, and Retried reads again', () async {
    bloc.add(const ServerSettingsStarted());
    await pumpEventQueue();
    remote.fetches.single.completeError(
      const SystemSettingsTransientException('down'),
    );
    await pumpEventQueue();
    expect(bloc.state, const ServerSettingsLoadFailed());
    expect(access.refreshCount, 0);

    bloc.add(const ServerSettingsRetried());
    await pumpEventQueue();
    expect(bloc.state, const ServerSettingsLoading());
    remote.fetches.last.complete(initial);
    await pumpEventQueue();

    expect(loaded().settings, initial);
    // Only a loaded state carries the revision on, so it starts again at 1.
    // The forms unmount while the read is out and take the values on mount.
    expect(loaded().revision, 1);
  });

  test('a save emits saving, then the new settings', () async {
    await load();

    bloc.add(const ServerSettingsGroupSaved(SettingsGroup.mail, _mailPatch));
    await pumpEventQueue();
    expect(loaded().saving, SettingsGroup.mail);
    expect(remote.updateCalls.single.id, 'settings-1');
    expect(remote.updateCalls.single.patch, _mailPatch);

    remote.updates.single.complete(saved);
    await pumpEventQueue();

    expect(
      bloc.state,
      ServerSettingsLoaded(
        settings: saved,
        mayUpdate: true,
        accessKnown: true,
        savedGroup: SettingsGroup.mail,
        revision: 2,
      ),
    );
  });

  test("a landed save removes that group's earlier failure only", () async {
    await load();
    bloc.add(const ServerSettingsGroupSaved(SettingsGroup.mail, _mailPatch));
    await pumpEventQueue();
    remote.updates.last.completeError(
      const SystemSettingsTransientException('x'),
    );
    await pumpEventQueue();
    bloc.add(
      const ServerSettingsGroupSaved(
        SettingsGroup.signIn,
        SystemSettingsPatch(),
      ),
    );
    await pumpEventQueue();
    expect(loaded().failures, {
      SettingsGroup.mail: SettingsSaveFailure.failed,
      SettingsGroup.signIn: SettingsSaveFailure.nothingChanged,
    });

    bloc.add(const ServerSettingsGroupSaved(SettingsGroup.mail, _mailPatch));
    await pumpEventQueue();
    remote.updates.last.complete(saved);
    await pumpEventQueue();

    expect(loaded().failures, {
      SettingsGroup.signIn: SettingsSaveFailure.nothingChanged,
    });
  });

  test('an empty patch is nothingChanged and sends nothing', () async {
    await load();

    bloc.add(
      const ServerSettingsGroupSaved(SettingsGroup.mail, SystemSettingsPatch()),
    );
    await pumpEventQueue();

    expect(loaded().failures, {
      SettingsGroup.mail: SettingsSaveFailure.nothingChanged,
    });
    expect(loaded().saving, isNull);
    expect(remote.updateCalls, isEmpty);
  });

  test('after a landed save, an empty patch clears the saved mark', () async {
    await load();
    bloc.add(const ServerSettingsGroupSaved(SettingsGroup.mail, _mailPatch));
    await pumpEventQueue();
    remote.updates.single.complete(saved);
    await pumpEventQueue();
    expect(loaded().savedGroup, SettingsGroup.mail);

    bloc.add(
      const ServerSettingsGroupSaved(SettingsGroup.mail, SystemSettingsPatch()),
    );
    await pumpEventQueue();

    expect(loaded().savedGroup, isNull);
    expect(loaded().failures, {
      SettingsGroup.mail: SettingsSaveFailure.nothingChanged,
    });
  });

  test('a save of the saved group clears the mark as it starts', () async {
    await load();
    bloc.add(const ServerSettingsGroupSaved(SettingsGroup.mail, _mailPatch));
    await pumpEventQueue();
    remote.updates.single.complete(saved);
    await pumpEventQueue();

    bloc.add(const ServerSettingsGroupSaved(SettingsGroup.mail, _mailPatch));
    await pumpEventQueue();

    expect(loaded().saving, SettingsGroup.mail);
    expect(loaded().savedGroup, isNull);
  });

  test('a sign-in save keeps the mail mark until it lands', () async {
    await load();
    bloc.add(const ServerSettingsGroupSaved(SettingsGroup.mail, _mailPatch));
    await pumpEventQueue();
    remote.updates.single.complete(saved);
    await pumpEventQueue();

    bloc.add(
      const ServerSettingsGroupSaved(SettingsGroup.signIn, _signInPatch),
    );
    await pumpEventQueue();
    expect(loaded().saving, SettingsGroup.signIn);
    expect(loaded().savedGroup, SettingsGroup.mail);

    remote.updates.last.complete(saved);
    await pumpEventQueue();

    expect(loaded().savedGroup, SettingsGroup.signIn);
  });

  group('a failed save', () {
    final cases = <String, (Object, SettingsSaveFailure, int)>{
      'password required': (
        const SmtpPasswordRequiredException('p'),
        SettingsSaveFailure.passwordRequired,
        0,
      ),
      'forbidden': (
        const SystemSettingsForbiddenException('f'),
        SettingsSaveFailure.refused,
        1,
      ),
      'permanent': (
        const SystemSettingsPermanentException('x'),
        SettingsSaveFailure.rejected,
        0,
      ),
      'transient': (
        const SystemSettingsTransientException('t'),
        SettingsSaveFailure.failed,
        0,
      ),
    };

    for (final entry in cases.entries) {
      test('${entry.key} is ${entry.value.$2.name}', () async {
        await load();
        bloc.add(
          const ServerSettingsGroupSaved(SettingsGroup.mail, _mailPatch),
        );
        await pumpEventQueue();
        remote.updates.single.completeError(entry.value.$1);
        await pumpEventQueue();

        expect(loaded().failures, {SettingsGroup.mail: entry.value.$2});
        expect(loaded().saving, isNull);
        expect(loaded().revision, 1);
        expect(loaded().settings, initial);
        expect(access.refreshCount, entry.value.$3);
      });
    }
  });

  test('a save while another is saving is dropped', () async {
    await load();
    bloc.add(const ServerSettingsGroupSaved(SettingsGroup.mail, _mailPatch));
    await pumpEventQueue();

    bloc.add(
      const ServerSettingsGroupSaved(SettingsGroup.signIn, _signInPatch),
    );
    await pumpEventQueue();

    expect(remote.updateCalls, hasLength(1));
    expect(loaded().saving, SettingsGroup.mail);
  });

  test('a save without update access is dropped', () async {
    access.current = _update(AccessExtent.none);
    await load();

    bloc.add(const ServerSettingsGroupSaved(SettingsGroup.mail, _mailPatch));
    await pumpEventQueue();

    expect(remote.updateCalls, isEmpty);
    expect(loaded().failures, isEmpty);
  });

  test('a save is dropped while access is unknown or absent', () async {
    final unknown = ServerSettingsBloc(
      remote: remote,
      access: FakeCallerAccessRepository(),
    );
    addTearDown(unknown.close);
    unknown.add(const ServerSettingsStarted());
    await pumpEventQueue();
    remote.fetches.last.complete(initial);
    await pumpEventQueue();
    expect(
      unknown.state,
      ServerSettingsLoaded(
        settings: initial,
        mayUpdate: false,
        accessKnown: false,
        revision: 1,
      ),
    );
    unknown.add(const ServerSettingsGroupSaved(SettingsGroup.mail, _mailPatch));
    await pumpEventQueue();

    final bare = ServerSettingsBloc(remote: remote);
    addTearDown(bare.close);
    bare.add(const ServerSettingsStarted());
    await pumpEventQueue();
    remote.fetches.last.complete(initial);
    await pumpEventQueue();
    bare.add(const ServerSettingsGroupSaved(SettingsGroup.mail, _mailPatch));
    await pumpEventQueue();

    expect(remote.updateCalls, isEmpty);
  });

  test("GroupEdited clears that group's failure only", () async {
    await load();
    bloc.add(
      const ServerSettingsGroupSaved(
        SettingsGroup.signIn,
        SystemSettingsPatch(),
      ),
    );
    await pumpEventQueue();
    bloc.add(
      const ServerSettingsGroupSaved(SettingsGroup.mail, SystemSettingsPatch()),
    );
    await pumpEventQueue();
    expect(loaded().failures, hasLength(2));

    bloc.add(const ServerSettingsGroupEdited(SettingsGroup.mail));
    await pumpEventQueue();

    expect(loaded().failures, {
      SettingsGroup.signIn: SettingsSaveFailure.nothingChanged,
    });
  });

  test("GroupEdited clears that group's saved mark", () async {
    await load();
    bloc.add(const ServerSettingsGroupSaved(SettingsGroup.mail, _mailPatch));
    await pumpEventQueue();
    remote.updates.single.complete(saved);
    await pumpEventQueue();
    bloc.add(
      const ServerSettingsGroupSaved(
        SettingsGroup.signIn,
        SystemSettingsPatch(),
      ),
    );
    await pumpEventQueue();
    expect(loaded().savedGroup, SettingsGroup.mail);

    bloc.add(const ServerSettingsGroupEdited(SettingsGroup.mail));
    await pumpEventQueue();

    expect(loaded().savedGroup, isNull);
    expect(loaded().failures, {
      SettingsGroup.signIn: SettingsSaveFailure.nothingChanged,
    });
  });

  test('editing the other group keeps the saved mark', () async {
    await load();
    bloc.add(const ServerSettingsGroupSaved(SettingsGroup.mail, _mailPatch));
    await pumpEventQueue();
    remote.updates.single.complete(saved);
    await pumpEventQueue();

    bloc.add(const ServerSettingsGroupEdited(SettingsGroup.signIn));
    await pumpEventQueue();

    expect(loaded().savedGroup, SettingsGroup.mail);
  });

  test('an access change updates the gating and leaves settings', () async {
    await load();

    access.current = _update(AccessExtent.none);
    await pumpEventQueue();

    expect(loaded().mayUpdate, isFalse);
    expect(loaded().accessKnown, isTrue);
    expect(loaded().settings, initial);
    expect(loaded().revision, 1);
  });

  blocTest<ServerSettingsBloc, ServerSettingsState>(
    'an access change before the read lands emits nothing',
    build: () => ServerSettingsBloc(remote: remote, access: access),
    act: (_) => access.current = _update(AccessExtent.none),
    expect: () => <ServerSettingsState>[],
  );

  test('events and the loading state compare by value', () {
    const patch = SystemSettingsPatch(smtpPort: 465);
    // Made at run time, so not identical to the const values they are
    // compared with: each comparison goes through props.
    final mail = SettingsGroup.values.byName('mail');

    expect(const ServerSettingsStarted().props, isEmpty);
    expect(const ServerSettingsLoading().props, isEmpty);
    expect(
      ServerSettingsGroupSaved(mail, patch),
      const ServerSettingsGroupSaved(SettingsGroup.mail, patch),
    );
    expect(
      const ServerSettingsGroupSaved(SettingsGroup.signIn, patch),
      isNot(const ServerSettingsGroupSaved(SettingsGroup.mail, patch)),
    );
    expect(
      ServerSettingsGroupEdited(mail),
      const ServerSettingsGroupEdited(SettingsGroup.mail),
    );
    expect(
      const ServerSettingsGroupEdited(SettingsGroup.signIn),
      isNot(const ServerSettingsGroupEdited(SettingsGroup.mail)),
    );
  });
}
