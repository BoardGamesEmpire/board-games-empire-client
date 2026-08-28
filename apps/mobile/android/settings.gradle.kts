pluginManagement {
    val flutterSdkPath = run {
        val properties = java.util.Properties()
        file("local.properties").inputStream().use { properties.load(it) }
        val flutterSdkPath = properties.getProperty("flutter.sdk")
        require(flutterSdkPath != null) { "flutter.sdk not set in local.properties" }
        flutterSdkPath
    }

    includeBuild("$flutterSdkPath/packages/flutter_tools/gradle")

    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

// Flutter 3.47 raised its Android floors: it fails the build below Gradle
// 8.14.0, AGP 8.11.1 or Kotlin 2.2.20, and the versions here were under all
// three. These are the 8.x ceilings, which clear every floor without the AGP 9
// migration — AGP 9 reads only the new DSL, which this app's build.gradle.kts
// is not written against yet. Flutter's own template is on Gradle 9.3.1 / AGP
// 9.1.0, so that migration is worth doing deliberately, on its own.
plugins {
    id("dev.flutter.flutter-plugin-loader") version "1.0.0"
    id("com.android.application") version "8.13.2" apply false
    id("org.jetbrains.kotlin.android") version "2.4.0" apply false
}

include(":app")
