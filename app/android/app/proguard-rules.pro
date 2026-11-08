# R8 / ProGuard 规则（release 构建开启 isMinifyEnabled + isShrinkResources）
#
# Flutter 引擎（io.flutter.*）的 keep 规则由 Flutter Gradle 插件自动注入，这里只补
# 「插件侧反射/序列化」与「本应用 Dart↔Native 接口」的兜底规则。
# 新增插件后如出现 release 专有的 ClassNotFoundException / NoSuchMethodException，
# 优先在此补规则而不是关掉 minify。

# ── 通用元数据 ──────────────────────────────────────────────
# 注解与泛型签名被 Tink / Gson 一类库在运行时读取
-keepattributes *Annotation*, Signature, InnerClasses, EnclosingMethod
# 崩溃栈可读性：保留行号，混淆后仍能定位
-keepattributes SourceFile, LineNumberTable
-renamesourcefileattribute SourceFile

# ── 本应用组件 ──────────────────────────────────────────────
# MainActivity 由系统按清单实例化，类名不可混淆
-keep class com.reai.recordingcard.** { *; }
# dart:ffi / platform channel 的 native 方法名不可改
-keepclasseswithmembernames class * {
    native <methods>;
}

# ── 安全存储（flutter_secure_storage → AndroidX Security + Tink + protobuf）──
-keep class androidx.security.crypto.** { *; }
-keep class com.google.crypto.tink.** { *; }
-keep class com.google.protobuf.** { *; }
-dontwarn androidx.security.crypto.**
-dontwarn com.google.crypto.tink.**
-dontwarn com.google.protobuf.**

# ── 其它插件（shared_preferences / package_info_plus / share_plus / path_provider）──
# 均为纯 Java 直调，无反射入口，无需额外 keep；
# 这些库自带的 consumer-rules 会随 AAR 一并生效。
-dontwarn io.flutter.plugin.**
-dontwarn javax.annotation.**
