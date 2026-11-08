plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "dev.kongkang.recording_card"
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
        applicationId = "dev.kongkang.recording_card"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = maxOf(flutter.minSdkVersion, 23)
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
        }
    }
    sourceSets.getByName("main").apply {
        java.srcDir(layout.buildDirectory.dir("generated/btleplug"))
        jniLibs.srcDir(layout.buildDirectory.dir("generated/card-jni"))
    }
}

flutter {
    source = "../.."
}

// No source/JNI classes are copied from an unpinned download: cargo metadata
// resolves the locked btleplug crate. OAuth intent filters remain independent.
val buildCardBridge by tasks.registering(Exec::class) {
    val rustRoot = project.file("../../rust/card_bridge")
    val local = java.util.Properties()
    val localFile = rootProject.file("local.properties")
    if (localFile.exists()) localFile.inputStream().use { local.load(it) }
    val sdk = System.getenv("ANDROID_SDK_ROOT") ?: local.getProperty("sdk.dir", "")
    environment("ANDROID_NDK_HOME", System.getenv("ANDROID_NDK_HOME") ?: "$sdk/ndk/${android.ndkVersion}")
    environment("CARD_JAVA_OUTPUT_DIR", layout.buildDirectory.dir("generated/btleplug").get().asFile.absolutePath)
    environment("CARD_JNI_OUTPUT_DIR", layout.buildDirectory.dir("generated/card-jni").get().asFile.absolutePath)
    commandLine("bash", rustRoot.resolve("scripts/build-android.sh").absolutePath)
    inputs.files(fileTree(rustRoot.resolve("src")), rustRoot.resolve("Cargo.toml"), rustRoot.resolve("Cargo.lock"))
    outputs.dirs(layout.buildDirectory.dir("generated/btleplug"), layout.buildDirectory.dir("generated/card-jni"))
}
tasks.named("preBuild").configure { dependsOn(buildCardBridge) }
