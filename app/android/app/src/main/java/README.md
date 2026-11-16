# btleplug Android Java 垫片（vendored）

来源：btleplug 0.12.0 crate 自带 `src/droidplug/java/src/main/java/`
（`~/.cargo/registry/src/<registry>/btleplug-0.12.0/src/droidplug/java/`）。
droidplug 的 Rust 侧通过 JNI 反射调用 `com.nonpolynomial.btleplug.android.impl.Adapter`
等类——这些 Java 类必须编进 APK，否则 `JNI_OnLoad` 阶段直接
`ClassNotFoundException` 崩溃（Jelly Star 2026-11-16 实测）。

升级 btleplug 版本时，用同路径的新版源码覆盖本目录并重新出包。
