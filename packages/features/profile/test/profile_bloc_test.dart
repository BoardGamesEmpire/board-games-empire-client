import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';
import 'package:profile/profile.dart';

import 'support/fake_user_profile_remote.dart';

const _patch = ProfilePatch(bio: SettingValue.set('Hello'));

void main() {
  late FakeUserProfileRemote remote;

  final profile = profileFixture();
  final stored = profileFixture(bio: 'Hello');
  final loaded = ProfileState(
    status: ProfileLoadStatus.loaded,
    profile: profile,
  );

  setUp(() {
    remote = FakeUserProfileRemote();
  });

  ProfileBloc build() => ProfileBloc(remote: remote);

  test('starts loading', () async {
    final bloc = build();

    expect(bloc.state, const ProfileState());
    expect(bloc.state.status, ProfileLoadStatus.loading);
    await bloc.close();
  });

  group('the read', () {
    blocTest<ProfileBloc, ProfileState>(
      'starts loading, then loaded',
      build: build,
      act: (bloc) async {
        bloc.add(const ProfileStarted());
        await pumpEventQueue();
        remote.fetches.single.complete(profile);
      },
      // bloc 9 emits a first state equal to the initial one.
      expect: () => [const ProfileState(), loaded],
    );

    blocTest<ProfileBloc, ProfileState>(
      'not found is notReady',
      build: build,
      act: (bloc) async {
        bloc.add(const ProfileStarted());
        await pumpEventQueue();
        remote.fetches.single.completeError(
          const UserProfileNotFoundException('none', statusCode: 404),
        );
      },
      expect: () => [
        const ProfileState(),
        const ProfileState(status: ProfileLoadStatus.notReady),
      ],
    );

    for (final error in <Object>[
      const UserProfileTransientException('down', statusCode: 503),
      const UserProfilePermanentException('odd', statusCode: 400),
      const UserProfileRefusedException('no', statusCode: 403),
      StateError('anything else'),
    ]) {
      blocTest<ProfileBloc, ProfileState>(
        'transient is failed, as is anything else (${error.runtimeType})',
        build: build,
        act: (bloc) async {
          bloc.add(const ProfileStarted());
          await pumpEventQueue();
          remote.fetches.single.completeError(error);
        },
        expect: () => [
          const ProfileState(),
          const ProfileState(status: ProfileLoadStatus.failed),
        ],
      );
    }

    blocTest<ProfileBloc, ProfileState>(
      'retry reads again',
      build: build,
      seed: () => const ProfileState(status: ProfileLoadStatus.failed),
      act: (bloc) async {
        bloc.add(const ProfileRetried());
        await pumpEventQueue();
        remote.fetches.single.complete(profile);
      },
      expect: () => [const ProfileState(), loaded],
      verify: (_) => expect(remote.fetches, hasLength(1)),
    );

    for (final firstLandsLast in [true, false]) {
      blocTest<ProfileBloc, ProfileState>(
        'a slow read superseded by a retry never lands: only the retry does '
        '(the first answers ${firstLandsLast ? 'last' : 'first'})',
        build: build,
        act: (bloc) async {
          bloc.add(const ProfileStarted());
          await pumpEventQueue();
          bloc.add(const ProfileRetried());
          await pumpEventQueue();
          final [first, retry] = remote.fetches;
          if (firstLandsLast) {
            retry.complete(stored);
            await pumpEventQueue();
            first.complete(profile);
          } else {
            first.complete(profile);
            await pumpEventQueue();
            retry.complete(stored);
          }
        },
        // The retry's loading equals the state before it, so only the
        // first is emitted.
        expect: () => [
          const ProfileState(),
          ProfileState(status: ProfileLoadStatus.loaded, profile: stored),
        ],
        verify: (_) => expect(remote.fetches, hasLength(2)),
      );
    }
  });

  group('the save', () {
    blocTest<ProfileBloc, ProfileState>(
      'a save sends the patch and takes the response as the profile, with '
      'saved true',
      build: build,
      seed: () => loaded,
      act: (bloc) async {
        bloc.add(const ProfileSaveRequested(_patch));
        await pumpEventQueue();
        remote.updates.single.complete(stored);
      },
      expect: () => [
        loaded.copyWith(saving: true),
        loaded.copyWith(profile: stored, saved: true),
      ],
      verify: (_) => expect(remote.updateCalls, [_patch]),
    );

    blocTest<ProfileBloc, ProfileState>(
      'a save retires the last outcome as it starts',
      build: build,
      seed: () => loaded.copyWith(saveFailure: () => ProfileSaveFailure.failed),
      act: (bloc) => bloc.add(const ProfileSaveRequested(_patch)),
      expect: () => [loaded.copyWith(saving: true)],
    );

    for (final (name, error, failure) in [
      (
        'a 400 is rejected',
        const UserProfilePermanentException('bad', statusCode: 400),
        ProfileSaveFailure.rejected,
      ),
      (
        'a 403 is refused',
        const UserProfileRefusedException('no', statusCode: 403),
        ProfileSaveFailure.refused,
      ),
      (
        'a transient save is failed',
        const UserProfileTransientException('down', statusCode: 503),
        ProfileSaveFailure.failed,
      ),
    ]) {
      blocTest<ProfileBloc, ProfileState>(
        name,
        build: build,
        seed: () => loaded,
        act: (bloc) async {
          bloc.add(const ProfileSaveRequested(_patch));
          await pumpEventQueue();
          remote.updates.single.completeError(error);
        },
        expect: () => [
          loaded.copyWith(saving: true),
          loaded.copyWith(saveFailure: () => failure),
        ],
      );
    }

    final argumentError = ArgumentError('refused before sending');
    blocTest<ProfileBloc, ProfileState>(
      'values the remote refuses before sending are rejected, and reported',
      build: build,
      seed: () => loaded,
      act: (bloc) async {
        bloc.add(const ProfileSaveRequested(_patch));
        await pumpEventQueue();
        remote.updates.single.completeError(argumentError);
      },
      expect: () => [
        loaded.copyWith(saving: true),
        loaded.copyWith(saveFailure: () => ProfileSaveFailure.rejected),
      ],
      errors: () => [argumentError],
    );

    for (final (name, error) in [
      (
        'a stored save whose answer did not map is a failed read',
        const UserProfilePermanentException('no profile', statusCode: 200),
      ),
      (
        'a stored save whose answer could not be decoded is a failed read',
        const UserProfileTransientException('no isolate', statusCode: 200),
      ),
    ]) {
      blocTest<ProfileBloc, ProfileState>(
        name,
        build: build,
        seed: () => loaded,
        act: (bloc) async {
          bloc.add(const ProfileSaveRequested(_patch));
          await pumpEventQueue();
          remote.updates.single.completeError(error);
        },
        expect: () => [
          loaded.copyWith(saving: true),
          const ProfileState(status: ProfileLoadStatus.failed),
        ],
      );
    }

    blocTest<ProfileBloc, ProfileState>(
      'a save answered with no profile is notReady, not a failed save',
      build: build,
      seed: () => loaded,
      act: (bloc) async {
        bloc.add(const ProfileSaveRequested(_patch));
        await pumpEventQueue();
        remote.updates.single.completeError(
          const UserProfileNotFoundException('gone', statusCode: 404),
        );
      },
      expect: () => [
        loaded.copyWith(saving: true),
        const ProfileState(status: ProfileLoadStatus.notReady),
      ],
    );

    blocTest<ProfileBloc, ProfileState>(
      'a second save while one runs is dropped',
      build: build,
      seed: () => loaded,
      act: (bloc) async {
        bloc
          ..add(const ProfileSaveRequested(_patch))
          ..add(
            const ProfileSaveRequested(
              ProfilePatch(pronouns: SettingValue.set('they/them')),
            ),
          );
        await pumpEventQueue();
        remote.updates.single.complete(stored);
        await pumpEventQueue();
      },
      expect: () => [
        loaded.copyWith(saving: true),
        loaded.copyWith(profile: stored, saved: true),
      ],
      verify: (_) => expect(remote.updateCalls, [_patch]),
    );

    group("the session check (#432): web's session cookie can move to "
        'another user under this tab', () {
      blocTest<ProfileBloc, ProfileState>(
        'a confirmed session sends the save',
        build: () =>
            ProfileBloc(remote: remote, confirmSession: () async => true),
        seed: () => loaded,
        act: (bloc) async {
          bloc.add(const ProfileSaveRequested(_patch));
          await pumpEventQueue();
          remote.updates.single.complete(stored);
        },
        expect: () => [
          loaded.copyWith(saving: true),
          loaded.copyWith(profile: stored, saved: true),
        ],
        verify: (_) => expect(remote.updateCalls, [_patch]),
      );

      for (final (name, confirm) in [
        ('a session that is no longer the user', () async => false),
        ('a session check that throws', () async => throw StateError('no')),
      ]) {
        blocTest<ProfileBloc, ProfileState>(
          '$name sends nothing, and the save fails',
          build: () => ProfileBloc(remote: remote, confirmSession: confirm),
          seed: () => loaded,
          act: (bloc) => bloc.add(const ProfileSaveRequested(_patch)),
          expect: () => [
            loaded.copyWith(saving: true),
            loaded.copyWith(saveFailure: () => ProfileSaveFailure.failed),
          ],
          verify: (_) => expect(remote.updateCalls, isEmpty),
        );
      }
    });

    blocTest<ProfileBloc, ProfileState>(
      'an empty patch sends nothing',
      build: build,
      seed: () => loaded,
      act: (bloc) => bloc.add(const ProfileSaveRequested(ProfilePatch())),
      expect: () => <ProfileState>[],
      verify: (_) => expect(remote.updateCalls, isEmpty),
    );

    blocTest<ProfileBloc, ProfileState>(
      'a save before the profile is read sends nothing',
      build: build,
      act: (bloc) => bloc.add(const ProfileSaveRequested(_patch)),
      expect: () => <ProfileState>[],
      verify: (_) => expect(remote.updateCalls, isEmpty),
    );
  });

  group('an edit', () {
    blocTest<ProfileBloc, ProfileState>(
      'an edit clears saved and the failure',
      build: build,
      seed: () => loaded.copyWith(saved: true),
      act: (bloc) => bloc.add(const ProfileEdited()),
      expect: () => [loaded],
    );

    blocTest<ProfileBloc, ProfileState>(
      'an edit clears a failure',
      build: build,
      seed: () =>
          loaded.copyWith(saveFailure: () => ProfileSaveFailure.rejected),
      act: (bloc) => bloc.add(const ProfileEdited()),
      expect: () => [loaded],
    );

    blocTest<ProfileBloc, ProfileState>(
      'an edit with nothing to retire changes nothing',
      build: build,
      seed: () => loaded,
      act: (bloc) => bloc.add(const ProfileEdited()),
      expect: () => <ProfileState>[],
    );
  });
}
