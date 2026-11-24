import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.example.nova_health"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        // Needed by the notifications plugin (modern Java time APIs on older Android versions).
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.example.nova_health"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = 26 // Health Connect needs Android 8.0 or newer
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

val validateNovaProductionConfig by tasks.registering(Exec::class) {
    val properties = Properties().apply {
        rootProject.file("local.properties").inputStream().use { load(it) }
    }
    val flutterSdk = requireNotNull(properties.getProperty("flutter.sdk"))
    val dartExecutable = if (System.getProperty("os.name").startsWith("Windows")) "dart.exe" else "dart"
    executable = "$flutterSdk/bin/cache/dart-sdk/bin/$dartExecutable"
    workingDir = projectDir.resolve("../..")
    args("tool/validate_release_config.dart")
    environment("DART_DEFINES", providers.gradleProperty("dart-defines").orElse("").get())
}

tasks.configureEach {
    if (name in setOf("preProfileBuild", "preReleaseBuild", "compileFlutterBuildProfile", "compileFlutterBuildRelease")) {
        dependsOn(validateNovaProductionConfig)
    }
}

dependencies {
    // Keep the heart-rate reader on the same Health Connect client as the permission plugin.
    implementation("androidx.health.connect:connect-client:1.1.0-alpha07")
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}
