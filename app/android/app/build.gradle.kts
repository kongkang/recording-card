import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// ── 发布签名配置 ──────────────────────────────────────────────
// 密钥信息放在 android/key.properties（已在 .gitignore，绝不入库），
// 模板见 android/key.properties.example。文件不存在时回退 debug 签名，
// 保证新机器 / CI 不配密钥也能 `flutter build apk --release` 出包自测。
val keystorePropertiesFile = rootProject.file("key.properties")
val keystoreProperties = Properties().apply {
    if (keystorePropertiesFile.exists()) {
        FileInputStream(keystorePropertiesFile).use { load(it) }
    }
}

fun requireProperty(name: String): String =
    keystoreProperties.getProperty(name)
        ?: throw GradleException(
            "android/key.properties 缺少字段 $name，请对照 android/key.properties.example 补全（生成命令见 docs/RELEASE.md）",
        )

val releaseStoreFile = if (keystorePropertiesFile.exists()) {
    // storeFile 相对路径按 android/app 解析，也兼容相对 android/ 的写法
    val raw = requireProperty("storeFile")
    val byAppDir = file(raw)
    if (byAppDir.exists()) byAppDir else rootProject.file(raw)
} else {
    null
}

android {
    namespace = "com.reai.recordingcard"
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
        // 与 iOS bundle id 保持一致：com.reai.recordingcard
        applicationId = "com.reai.recordingcard"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName

        val includeAllAbis = System.getenv("RC_ANDROID_ALL_ABIS") == "1" ||
            project.findProperty("RC_ANDROID_ALL_ABIS")?.toString() == "1"
        if (!includeAllAbis) {
            ndk {
                abiFilters += "arm64-v8a"
            }
        }
    }

    signingConfigs {
        if (releaseStoreFile != null) {
            create("release") {
                keyAlias = requireProperty("keyAlias")
                keyPassword = requireProperty("keyPassword")
                storeFile = releaseStoreFile
                storePassword = requireProperty("storePassword")
            }
        }
    }

    buildTypes {
        release {
            if (releaseStoreFile != null) {
                signingConfig = signingConfigs.getByName("release")
            } else {
                signingConfig = signingConfigs.getByName("debug")
                logger.warn(
                    "\n⚠️  未找到 android/key.properties：release 构建将使用 debug 签名，产物**不能**上传 Google Play。\n" +
                        "    生成上传密钥与配置文件的步骤见 docs/RELEASE.md。\n",
                )
            }
            // 代码与资源压缩：体积收益明显，规则见 proguard-rules.pro
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android.txt"),
                "proguard-rules.pro",
            )
        }
    }

    lint {
        // release 出包不被 lint 静态检查中断；lint 单独用 `./gradlew lint` 把关
        checkReleaseBuilds = false
        abortOnError = false
    }
}

flutter {
    source = "../.."
}

// ── Release 构建修正：剥掉 dev 依赖插件的注册行 ───────────────────────────────
//
// Flutter 生成的 GeneratedPluginRegistrant.java 会把 dev_dependencies 里的
// integration_test 也注册进去，但它的 Android 库在 release 配置里不可用，
// javac 会报「程序包 dev.flutter.plugins.integration_test 不存在」。
// release 本来就不该注册测试插件，这里在编译前把这一行去掉。
// 注意：只影响 release 的 Java 编译输入，不改 debug/profile，也不动 ios。
tasks.whenTaskAdded {
    if (name.endsWith("JavaWithJavac") && name.contains("Release")) {
        doFirst {
            val registrant = file("src/main/java/io/flutter/plugins/GeneratedPluginRegistrant.java")
            if (registrant.exists()) {
                val kept = registrant.readLines().filterNot { it.contains("integration_test") }
                registrant.writeText(kept.joinToString("\n"))
            }
        }
    }
}

// ── Rust 桥：Android 原生库 ────────────────────────────────────────────────────
//
// card_bridge 是 Rust cdylib（app/rust/card_bridge），.so 放在 src/main/jniLibs
// 下由 AGP 自动打进 APK。jniLibs 是构建产物，所以要在打包前确保它存在。
//
// 设计取舍：
// - **默认只在缺失时构建**（`rust.build=true` 可强制重建）。理由：cargo 交叉编译
//   约 15 秒且会和其它 Flutter/Gradle 任务抢 Cargo 的全局文件锁，每次构建都跑
//   容易卡在 "Blocking waiting for file lock"。
// - Rust 源码或脚本改动后，用 `flutter build apk -Prust.build=true` 或直接
//   `bash rust/build-android.sh` 重建。
val rustSo = file("src/main/jniLibs/arm64-v8a/libcard_bridge.so")
val forceRustBuild = project.hasProperty("rust.build")
val skipRustBuild = project.hasProperty("rust.skip")

val buildRustBridge = tasks.register<Exec>("buildRustBridge") {
    workingDir = file("../../rust")
    commandLine("bash", "build-android.sh")
    inputs.dir("../../rust/card_bridge/src")
    inputs.file("../../rust/card_bridge/Cargo.toml")
    inputs.file("../../rust/build-android.sh")
    outputs.dir("src/main/jniLibs")
    isIgnoreExitValue = false
    enabled = !skipRustBuild && (forceRustBuild || !rustSo.exists())
}

tasks.matching { it.name.startsWith("merge") && it.name.endsWith("JniLibFolders") }
    .configureEach { dependsOn(buildRustBridge) }
