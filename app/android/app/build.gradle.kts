import java.nio.ByteBuffer
import java.nio.charset.CodingErrorAction
import java.util.Base64

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// BEGIN RC_OAUTH_CONFIG: pure functions also exercised by scripts/tests.
fun decodeRcDartDefines(encoded: String): Map<String, String> {
    if (encoded.isEmpty()) return emptyMap()
    val result = linkedMapOf<String, String>()
    for (entry in encoded.split(',')) {
        require(entry.isNotEmpty()) { "Empty entry in Flutter dart-defines" }
        val decoded = try {
            val bytes = Base64.getDecoder().decode(entry)
            Charsets.UTF_8.newDecoder()
                .onMalformedInput(CodingErrorAction.REPORT)
                .onUnmappableCharacter(CodingErrorAction.REPORT)
                .decode(ByteBuffer.wrap(bytes)).toString()
        } catch (_: Exception) {
            throw IllegalArgumentException("Flutter dart-defines must be valid Base64 UTF-8")
        }
        val separator = decoded.indexOf('=')
        require(separator > 0) { "Each Flutter dart-define must contain key=value" }
        val key = decoded.substring(0, separator)
        require(!result.containsKey(key)) { "Duplicate Flutter dart-define; use one approved CONFIG without overrides" }
        result[key] = decoded.substring(separator + 1)
    }
    return result
}

fun rcOAuthCallbackScheme(defines: Map<String, String>): String {
    val flags = listOf(
        "RC_OAUTH_REUSE_REFERENCE_CLIENT", "RC_ASR_ALLOW_DOWNLOAD",
        "RC_ASR_LICENSE_ACCEPTED", "RC_UPLOAD_RAW_CONTRACT_APPROVED",
        "RC_UPLOAD_OAUTH_BEARER_APPROVED",
    )
    for (flag in flags) {
        require(defines[flag] == null || defines[flag] in listOf("true", "false")) {
            "$flag must be exactly true or false"
        }
    }
    val reuse = defines["RC_OAUTH_REUSE_REFERENCE_CLIENT"] == "true"
    val client = defines["RC_OAUTH_CLIENT_ID"] ?: "58Ff3x3aEtw2DZHo19CP6Hpw5fpfL1vo"
    val redirect = defines["RC_OAUTH_REDIRECT_URI"] ?: "recording-card://callback"
    val expected = if (reuse) "reai-mobile://callback" else "recording-card://callback"
    require(redirect == expected) {
        "RC_OAUTH_REDIRECT_URI must exactly match the explicit reuse flag ($expected)"
    }
    require(client.isNotEmpty() && client.none { it.isWhitespace() }) {
        "RC_OAUTH_CLIENT_ID must name an approved public client"
    }
    require(!reuse || client == "58Ff3x3aEtw2DZHo19CP6Hpw5fpfL1vo") {
        "Reference reuse is restricted to the agreed public client ID"
    }
    return if (reuse) "reai-mobile" else "recording-card"
}
// END RC_OAUTH_CONFIG

val nativeOAuthCallbackScheme = rcOAuthCallbackScheme(
    decodeRcDartDefines(providers.gradleProperty("dart-defines").orNull ?: ""),
)
if (nativeOAuthCallbackScheme == "reai-mobile") {
    logger.warn("Explicit reference OAuth reuse: uninstall the reference ReAI app from the test phone or use another phone. Two installed apps must NOT share reai-mobile; token storage remains recording_card.")
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
        manifestPlaceholders["rcOAuthCallbackScheme"] = nativeOAuthCallbackScheme
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
