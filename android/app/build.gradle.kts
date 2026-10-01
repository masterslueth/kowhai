import java.util.Properties

plugins {
    id("com.android.application")
    id("kotlin-android")
    id("dev.flutter.flutter-gradle-plugin")
    id("com.google.gms.google-services")
    id("com.google.firebase.crashlytics")
}

val keyProperties = Properties()
val keyPropertiesFile = rootProject.file("key.properties")
if (keyPropertiesFile.exists()) {
    keyPropertiesFile.inputStream().use { keyProperties.load(it) }
    println("BUILD LOG: key.properties loaded successfully.")
} else {
    println("BUILD LOG: key.properties NOT FOUND at ${keyPropertiesFile.absolutePath}")
}

android {
    namespace = "com.mattsteed.kowhai"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    lint {
        // This stops Lint from killing the build for minor plugin warnings
        checkReleaseBuilds = false
        abortOnError = false
    }

    defaultConfig {
        applicationId = "com.mattsteed.kowhai"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        // We create the release config regardless, but only populate it if we have the data.
        // Supports two modes:
        //   1. Local dev  — keystore via KEYSTORE_PATH env var, or
        //      <user-home>/.android/keys/kowhai-release.jks fallback
        //   2. CI (GitHub Actions) — KEYSTORE_PATH env var + key.properties generated from secrets
        create("release") {
            val ciKeystorePath = System.getenv("KEYSTORE_PATH")
            val userHome = System.getProperty("user.home")
            val ksFile = when {
                !ciKeystorePath.isNullOrEmpty() -> file(ciKeystorePath)
                !userHome.isNullOrEmpty() -> file("$userHome/.android/keys/kowhai-release.jks")
                else -> null
            }

            if (ksFile != null && ksFile.exists() && keyProperties.containsKey("storePassword")) {
                storeFile = ksFile
                storePassword = keyProperties["storePassword"] as String
                keyAlias = keyProperties["keyAlias"] as String
                keyPassword = keyProperties["keyPassword"] as String
                println("BUILD LOG: Signing configuration applied for Release.")
            } else {
                println("BUILD LOG: Signing configuration SKIPPED. File exists: ${ksFile != null && ksFile.exists()}")
            }
        }
    }

    buildTypes {
        release {
            // Use the = syntax to be absolutely direct
            signingConfig = signingConfigs.getByName("release")

            // DEFERRED - do not flip without a device install test.
            //
            // R8 strips the APK down so the shipped binary is not a readable
            // copy of the app. Enabling it is worthwhile, but a missing keep
            // rule surfaces only at RUNTIME and typically only in release -
            // e.g. audio_service's notification, Media3 extractors, or Cast
            // session setup failing after install. A green `flutter build apk`
            // does NOT clear that, exactly as the path_provider_android NDK
            // pin in pubspec.yaml documents.
            //
            // Static verification already done (see proguard-rules.pro): R8 was
            // enabled, and the release DEX was dexdumped to confirm every
            // AndroidManifest-referenced class - MainActivity, AudioService,
            // AudioServiceActivity, MediaButtonReceiver, the Cast options
            // provider and notification service, FlutterActivity - survived
            // present and un-renamed. That proves the launch path but NOT
            // runtime behaviour, so minification stays off until someone can
            // install a release build on real hardware.
            isMinifyEnabled = false
            isShrinkResources = false
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
        }

        debug {
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

flutter {
    source = "../.."
}