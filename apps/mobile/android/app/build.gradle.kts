plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.boardgamesempire.mobile.mobile"

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
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.boardgamesempire.mobile.mobile"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
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
