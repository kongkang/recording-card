package com.reai.recordingcard

import io.flutter.embedding.android.FlutterActivity

class MainActivity : FlutterActivity() {
    companion object {
        init {
            // Android：必须从 Java 侧加载 card_bridge，JNI_OnLoad 才会被 ART 调用，
            // 把 JavaVM 交给 btleplug droidplug 后端（裸 dlopen 不触发 JNI_OnLoad）。
            // 加载后 Dart 侧 DynamicLibrary.process() 即可看到桥符号。
            System.loadLibrary("card_bridge")
        }
    }
}
