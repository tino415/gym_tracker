import java.util.Properties

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val playUpload = System.getenv("PLAY_UPLOAD") != null
val uploadProperties = Properties().apply {
    if (playUpload) file("../key.properties").inputStream().use { load(it) }
}

android {
    namespace = "com.otin.gym_tracker"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.otin.gym_tracker"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = 30
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (playUpload) {
            create("upload") {
                storeFile = file(uploadProperties.getProperty("storeFile"))
                storePassword = uploadProperties.getProperty("storePassword")
                keyAlias = uploadProperties.getProperty("keyAlias")
                keyPassword = uploadProperties.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            // The installed apps carry the debug key, and `pm install -r` only
            // upgrades over the same signature.
            signingConfig = signingConfigs.getByName(if (playUpload) "upload" else "debug")
        }
    }
}

flutter {
    source = "../.."
}

dependencies {
    implementation("com.google.android.gms:play-services-wearable:18.1.0")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.7.3")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-play-services:1.7.3")
    // Ongoing Activity (Wear OS chip + foreground notification adornment).
    implementation("androidx.wear:wear-ongoing:1.0.0")
    implementation("androidx.core:core-ktx:1.13.1")
    // Heart rate sampling via Wear Health Services MeasureClient.
    implementation("androidx.health:health-services-client:1.1.0-alpha05")
    // health-services-client's unregisterMeasureCallbackAsync returns
    // com.google.common.util.concurrent.ListenableFuture, so Guava must be on
    // the compile classpath. The -android flavour is the right one for AOSP.
    implementation("com.google.guava:guava:32.1.3-android")
    // Health Connect, for writing finished workouts to the phone's health
    // store. Phone-only in practice — Wear has no Health Connect provider, so
    // the bridge reports it unavailable there and does nothing.
    implementation("androidx.health.connect:connect-client:1.1.0")
}
