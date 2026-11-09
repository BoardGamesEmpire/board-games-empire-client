import java.util.Properties

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// The release key (#51), from the environment or android/key.properties,
// input by input, the environment winning. A relative store file is
// relative to android/, where key.properties lives, whichever source names
// it. The variables carry a BGE_ prefix so that ANDROID_* ones exported for
// another project's build can't reach this one. docs/dev/android-signing.md
// has the setup.
val keyProperties = Properties().apply {
    val file = rootProject.file("key.properties")
    if (file.exists()) file.inputStream().use { load(it) }
}

data class ReleaseKey(
    val storeFile: String,
    val storePassword: String,
    val keyAlias: String,
    val keyPassword: String,
)

// Each input's environment variable and key.properties key, in
// ReleaseKey's order.
val releaseKeyInputs = listOf(
    "BGE_ANDROID_KEYSTORE_PATH" to "storeFile",
    "BGE_ANDROID_KEYSTORE_PASSWORD" to "storePassword",
    "BGE_ANDROID_KEY_ALIAS" to "keyAlias",
    "BGE_ANDROID_KEY_PASSWORD" to "keyPassword",
)
val releaseKeyValues = releaseKeyInputs.map { (env, property) ->
    System.getenv(env)?.takeIf { it.isNotEmpty() }
        ?: keyProperties.getProperty(property)?.takeIf { it.isNotEmpty() }
}
val missingReleaseKey = releaseKeyInputs.filterIndexed { i, _ ->
    releaseKeyValues[i] == null
}
val releaseKey = releaseKeyValues.filterNotNull()
    .takeIf { missingReleaseKey.isEmpty() }
    ?.let { (storeFile, storePassword, keyAlias, keyPassword) ->
        ReleaseKey(storeFile, storePassword, keyAlias, keyPassword)
    }

// Half a key never falls back to the debug one. A debug-signed APK from a
// build that meant to sign would be refused as an update by every
// installed copy.
if (releaseKey == null && missingReleaseKey.size < releaseKeyInputs.size) {
    throw GradleException(
        "The release key is only partly configured. Missing: " +
            missingReleaseKey.joinToString { (env, property) ->
                "$env (or $property in android/key.properties)"
            } +
            ". Set all four, or none to sign with the debug key (#51).",
    )
}
if (releaseKey == null && System.getenv("BGE_REQUIRE_RELEASE_SIGNING") == "true") {
    throw GradleException(
        "Release signing is required here, but no release key is " +
            "configured: set " +
            releaseKeyInputs.joinToString { (env, property) ->
                "$env (or $property in android/key.properties)"
            } +
            " (#51).",
    )
}

android {
    namespace = "com.boardgamesempire.app"

    // Pinned ahead of `flutter.compileSdkVersion`, which is still 36 on
    // Flutter 3.47.1. flutter_secure_storage 11 compiles its own Android
    // library at 37, and Gradle fails a build whose app compileSdk is
    // lower than a dependency's. Drop this line and go back to the
    // Flutter default once a Flutter release raises it to 37 or higher.
    compileSdk = 37
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }

    defaultConfig {
        // The macOS app's bundle id. It can't change once an APK is
        // sideloaded: Android treats a new id as another app, installed
        // beside the old one with none of its data (#51).
        applicationId = "com.boardgamesempire.app"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (releaseKey != null) {
            create("release") {
                storeFile = rootProject.file(releaseKey.storeFile)
                storePassword = releaseKey.storePassword
                keyAlias = releaseKey.keyAlias
                keyPassword = releaseKey.keyPassword
            }
        }
    }

    buildTypes {
        release {
            // Without the release key, the debug key. Forks, contributors
            // and PR runs build without it, and their APKs install fine on
            // their own. CI's master push sets BGE_REQUIRE_RELEASE_SIGNING,
            // so it can't silently ship a debug APK (#51).
            signingConfig = signingConfigs.getByName(
                if (releaseKey != null) "release" else "debug",
            )
        }
    }
}

// Only a build that packages the release APK hears about the fallback, so
// debug runs stay quiet. Logged at the quiet level because Flutter runs
// Gradle with -q, which drops warnings.
if (releaseKey == null) {
    gradle.taskGraph.whenReady {
        if (hasTask("${project.path}:packageRelease")) {
            logger.quiet(
                "Warning: no release key is configured, so the release APK " +
                    "is signed with the debug key. It won't install over a " +
                    "release-signed one (#51).",
            )
        }
    }
}

// Kotlin 2.4 removed the `kotlinOptions { jvmTarget = <String> }` DSL that used
// to live in the `android` block above — setting it there is now a hard error,
// not a deprecation. The replacement is typed (`JvmTarget`) and hangs off the
// top-level `kotlin` extension rather than off `android`.
kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_11
    }
}

flutter {
    source = "../.."
}
