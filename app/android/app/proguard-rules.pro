# btleplug accesses these classes only through JNI. Preserve them in release.
-keep class com.nonpolynomial.** { *; }
-keep class io.github.gedgygedgy.** { *; }
-keep class dev.kongkang.recording_card.CardNative { *; }
-keepclasseswithmembernames class * { native <methods>; }
