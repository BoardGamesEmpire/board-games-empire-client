# Signing the Android APK

Android installs an APK over an earlier one only when both are signed with the
same key, and when its `versionCode` is no lower. Every APK that master's CI
run uploads is signed with one release key, and CI gives each one a
`versionCode` of the first-parent commit count of the commit it builds (#419).
That count only grows along master, so each APK installs as an update over the
one before and keeps the user's data. A local `melos run build-mobile-android`
without `--build-number` takes the `+1` committed in the app's `version:`
instead, so it won't install over a CI build. This page is for maintainers:
making that key, handing it to CI, and signing a local build with it.

`tool/build_android.dart` is the one release build, for
`melos run build-mobile-android` and CI's `Android build` job alike. Gradle
(`apps/mobile/android/app/build.gradle.kts`) picks the key.

## How a build gets its key

Gradle reads four inputs. Each comes from the environment when it is set and
non-empty, and otherwise from `apps/mobile/android/key.properties`:

| Environment variable            | `key.properties` key | Meaning                 |
| ------------------------------- | -------------------- | ----------------------- |
| `BGE_ANDROID_KEYSTORE_PATH`     | `storeFile`          | The keystore file       |
| `BGE_ANDROID_KEYSTORE_PASSWORD` | `storePassword`      | The keystore's password |
| `BGE_ANDROID_KEY_ALIAS`         | `keyAlias`           | The key's alias in it   |
| `BGE_ANDROID_KEY_PASSWORD`      | `keyPassword`        | The key's own password  |

A relative keystore path, from either source, is relative to
`apps/mobile/android/`, where `key.properties` lives.

The variables carry a `BGE_` prefix so that `ANDROID_*` ones exported for
another project's build can't reach this one. Without it, a shell set up for
another app would sign this one with that app's key, or fail every build here
as half a key.

- **All four set:** the release APK is signed with the release key.
- **None set:** it is signed with the debug key, and the build prints a warning.
  That is the normal case for contributors, forks and PR runs. A debug-signed
  APK installs on a device that has no release-signed copy, but Android refuses
  it as an update over one. `flutter run` answers that refusal by uninstalling
  the release-signed copy, which deletes its data.
- **Some set:** the build fails and names the missing inputs. Half a key never
  falls back to the debug one, because a build that meant to sign would ship an
  APK no installed copy accepts.

`BGE_REQUIRE_RELEASE_SIGNING=true` turns the debug fallback into a failure too.
`dart run tool/build_android.dart --require-release-signing` sets it, and then
also refuses an APK signed by anything but the release key: the debug key, or
any other key, however valid. It knows the release key by its certificate's
SHA-256 digest, `_releaseCertificate` in `tool/build_android.dart`. CI's
`release-android` job uses that flag, so it can't upload an APK whose key won't
install over the last one. A keystore secret replaced with another key fails
the job rather than ship.

## Generating the key

Once, for the life of the app. Run it outside the repository: only
`apps/mobile/android/` ignores keystore files, so one made elsewhere in the
checkout could be committed.

```sh
keytool -genkeypair -v -keystore bge-release.jks -keyalg RSA -keysize 4096 \
  -validity 10000 -alias bge-release
```

`keytool` asks for the keystore's password and the certificate's name fields.
Its default keystore type, PKCS12, has no separate key password: the key's
password is the keystore's. So the key password, wherever it goes (the
`ANDROID_KEY_PASSWORD` secret, `BGE_ANDROID_KEY_PASSWORD` or `keyPassword`),
takes the same value as the keystore's.

The name fields end up in every APK, where anyone can read them, and Android
ignores them. A project name in the first two is enough, and the rest can be
left blank. Don't use `CN=Android Debug`, the name the build takes for the
debug key.

Then record the certificate's SHA-256 digest, the `SHA256:` line of:

```sh
keytool -list -v -keystore bge-release.jks -alias bge-release
```

It goes in `_releaseCertificate` in `tool/build_android.dart`, by pull request,
as `keytool` prints it. It isn't secret: every APK carries the certificate.
Until it is there, `release-android` refuses the APK the new key signs.

## Back it up offline

Losing the key, or its password, means no later APK installs over any copy
already out there. Every user then has to uninstall the app and install a build
signed with a new key, and uninstalling deletes the app's local data. The app
opts out of Android's backups (its databases are encrypted with a key that never
leaves the device), so nothing restores it.

Keep a copy of the keystore and its password somewhere offline, apart from
the machine you made it on. Anyone with the key can sign an APK that installs
over the real app, so keep it secret too.

Replacing the key, lost or not, costs the same uninstall. It is a pull request
that changes `_releaseCertificate`, merged before the new key's secrets go to
CI, and a note to every tester that the next APK won't install over the last.
The master run that merge starts still holds the old key's secrets, so its
`release-android` refuses the APK and uploads nothing. Once the new secrets are
set, re-run that job (the run's "Re-run failed jobs", or
`gh run rerun <run-id> --failed`) and check that it uploads `android-apk`.

## Handing it to CI

The key lives in an `android-release` environment, not in repository secrets.
GitHub hands a job an environment's secrets only once the environment's branch
rule passes, and this one admits `master` alone. So only CI's `release-android`
job, which runs on pushes to master, can read them. A pull request's run can't,
even one that edits the workflow to name the environment. A repository secret,
by contrast, reaches every run in the repository, a pull request's included.

1. **The environment.** Settings → Environments → New environment, named
   `android-release`. Under "Deployment branches and tags", pick "Selected
   branches and tags" and add the branch rule `master`. Add no required
   reviewers: master uploads without waiting for anyone. Or, with `gh`:

   ```sh
   gh api -X PUT repos/BoardGamesEmpire/board-games-empire-client/environments/android-release \
     -F 'deployment_branch_policy[protected_branches]=false' \
     -F 'deployment_branch_policy[custom_branch_policies]=true'
   gh api -X POST repos/BoardGamesEmpire/board-games-empire-client/environments/android-release/deployment-branch-policies \
     -f name=master -f type=branch
   ```

2. **The four secrets, as the environment's.** From the directory holding the
   keystore, in a checkout of this repository:

   ```sh
   base64 -i bge-release.jks | gh secret set ANDROID_KEYSTORE_BASE64 --env android-release   # macOS
   # Linux: base64 -w0 bge-release.jks | gh secret set ANDROID_KEYSTORE_BASE64 --env android-release
   gh secret set ANDROID_KEYSTORE_PASSWORD --env android-release
   gh secret set ANDROID_KEY_ALIAS --env android-release
   gh secret set ANDROID_KEY_PASSWORD --env android-release
   ```

   The last three prompt for their values, so the passwords stay out of your
   shell history. The alias is `bge-release` if you used the command above.
   Don't also set them as repository secrets: `gh secret list`, without
   `--env`, shouldn't name them.

3. **Master itself.** The environment trusts whatever workflow master holds,
   so the key is only as safe as master is. A ruleset on master that requires
   a pull request, and blocks force pushes and deletion, keeps anyone from
   pushing a workflow that reads the key straight onto it.

`release-android` decodes the keystore into the runner's temporary directory,
builds with `--require-release-signing`, uploads the APK, and deletes the
keystore. A missing keystore secret fails the job with an error naming it, and
a missing password or alias fails the build. Either fails only that job: the
web image still publishes.

## Signing a local build

Create `apps/mobile/android/key.properties`. It is gitignored.

```properties
storeFile=/path/to/bge-release.jks
storePassword=<the keystore's password>
keyAlias=bge-release
keyPassword=<the keystore's password again>
```

Then build:

```sh
melos run build-mobile-android
# or, to fail rather than fall back to the debug key:
dart run tool/build_android.dart --require-release-signing
```

The APK and its checksum land in `apps/mobile/build/release/`.

## Checking a build's signer

`tool/build_android.dart` prints the signer of every APK it builds. To check an
APK you downloaded, use `apksigner` from the Android SDK's build-tools:

```sh
apksigner verify --print-certs bge-1.0.0-android-universal.apk
```

The certificate DN is `CN=Android Debug` for a debug-signed APK. A
release-signed one's certificate SHA-256 digest is `_releaseCertificate` in
`tool/build_android.dart`, which `keytool` prints with colons and in upper case
where `apksigner` prints neither.
