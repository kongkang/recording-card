# Project-local Apple notification extension

Source: cached registry `btleplug 0.12.0`, crate checksum `52c3264dbe2c8e29381e4e95aa2d2783ad0b9192b511240f3755b7e5e3cee87e`. All upstream `src/` files, README, the complete `LICENSE.md`, and `Cargo.toml.orig` are retained. The working Cargo manifest is the upstream original with only the standalone `[workspace]` / test-workspace exclusion removed. Upstream hardware integration tests, examples, caches, Git metadata and build products are not vendored. Version remains 0.12.0; this is not an upstream release.

Only two upstream production files are changed:

- `src/corebluetooth/peripheral.rs`: Apple notification broadcast capacity changes from 16 to the named, power-of-two `APPLE_NOTIFICATION_CAPACITY = 1024`; additive inherent `notifications_with_errors()` subscribes to the same broadcast once. It does not start a manager, scan, connect or create a second CoreBluetooth subscription.
- `src/common/util.rs`: an Apple-only fallible stream yields `RuntimeError` with the `Lagged(n)` count once and then EOF. It does not return the retained suffix after loss. The upstream infallible trait converter is unchanged. Six Apple host-only tests exercise actual Tokio broadcast behavior, FIFO retention, the legacy swallowed error, a full 1024-entry burst, overflow, pending-reader lag and closure without hardware.

The SDK selects this path crate under the Apple-only `btleplug_apple` dependency alias. Non-Apple SDK builds and the bridge's direct Android dependency keep registry btleplug. No workspace-wide patch or user Cargo configuration is applied. The SDK NUS transport consumes the fallible stream and maps its error to the existing `SdkError::Transport`; the existing SDK worker invalidates its terminal/epoch state. Native/Dart interfaces, start/end handling, byte validation, cancellation finalization and source retention are unchanged. The DFU caller continues using the upstream infallible trait API; no OTA behavior is claimed to be fixed or tested.

The bounded buffer retains at most 1024 notification entries per peripheral (not per receiver). At a 201-byte NUS value including one protocol marker, retained payload is at most 205824 bytes; at the Bluetooth 512-byte attribute-value limit it is at most 524288 bytes, plus entry/synchronization/allocator overhead. This code bounds entry count, not arbitrary `Vec` byte size; it does not enforce a separate 512-byte payload cap. The existing SDK unbounded inbox and other upstream channels are outside this buffer's memory bound. The capacity only tolerates longer scheduling stalls; it is not a no-loss guarantee. Overflow still fails closed.

The full `LICENSE.md` includes MIT, Apache-2.0 and the BSD 3-Clause notice inherited from blurmac. Preserve it in binary-distribution notices/assets alongside the SDK MIT license; do not label the newly vendored btleplug code as SDK-MIT-only.

No Bluetooth hardware was accessed during this change. The observed iPhone short read remains a candidate mechanism, not a proved incident attribution.
