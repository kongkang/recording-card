//! Project-local counters only: no payload retention, logging, queue or BLE work.
use std::sync::{
    Arc, OnceLock, RwLock, Weak,
    atomic::{AtomicU64, Ordering::Relaxed},
};
use uuid::Uuid;

#[derive(Clone, Copy, Eq, PartialEq)]
struct Target(Uuid, Uuid, Uuid);
static TARGETS: OnceLock<RwLock<Vec<(Target, Weak<NotificationDiagnostics>)>>> = OnceLock::new();
static NEXT_EPOCH: AtomicU64 = AtomicU64::new(1);

#[derive(Default)]
pub(crate) struct PacketCounters {
    packets: AtomicU64,
    bytes: AtomicU64,
    leading_zero_packets: AtomicU64,
    leading_zero_raw_bytes: AtomicU64,
    leading_zero_payload_bytes: AtomicU64,
    empty_packets: AtomicU64,
}
impl PacketCounters {
    pub(crate) fn observe(&self, data: &[u8]) {
        self.packets.fetch_add(1, Relaxed);
        self.bytes.fetch_add(data.len() as u64, Relaxed);
        if data.first() == Some(&0) {
            self.leading_zero_packets.fetch_add(1, Relaxed);
            self.leading_zero_raw_bytes
                .fetch_add(data.len() as u64, Relaxed);
            self.leading_zero_payload_bytes
                .fetch_add((data.len() - 1) as u64, Relaxed);
        }
        if data.is_empty() {
            self.empty_packets.fetch_add(1, Relaxed);
        }
    }
    fn snapshot(&self, prefix: &'static str, out: &mut Vec<(String, u64)>) {
        for (name, counter) in [
            ("packets", &self.packets),
            ("bytes", &self.bytes),
            ("leading_zero_packets", &self.leading_zero_packets),
            ("leading_zero_raw_bytes", &self.leading_zero_raw_bytes),
            (
                "leading_zero_payload_bytes",
                &self.leading_zero_payload_bytes,
            ),
            ("empty_packets", &self.empty_packets),
        ] {
            out.push((format!("{prefix}_{name}"), counter.load(Relaxed)));
        }
    }
}

/// Fresh connection-target observation epoch. Snapshot loads are deliberately
/// non-fenced: they do not drain queues or establish a common notification cut.
#[derive(Default)]
pub struct NotificationDiagnostics {
    epoch: u64,
    pub(crate) callback_copy: PacketCounters,
    pub(crate) internal_dequeue: PacketCounters,
    pub(crate) read_divert: PacketCounters,
    pub(crate) map_miss: PacketCounters,
    pub(crate) peripheral_send: PacketCounters,
    pub(crate) peripheral_dequeue: PacketCounters,
    pub(crate) broadcast_publish: PacketCounters,
    consumer: PacketCounters,
    pub(crate) callback_total: AtomicU64,
    pub(crate) callback_error: AtomicU64,
    pub(crate) callback_value_none: AtomicU64,
    pub(crate) callback_raw_bytes: AtomicU64,
    pub(crate) callback_copy_len_mismatch: AtomicU64,
    pub(crate) delegate_send_attempt: AtomicU64,
    pub(crate) delegate_send_ok: AtomicU64,
    pub(crate) delegate_send_error: AtomicU64,
    pub(crate) map_miss_peripheral: AtomicU64,
    pub(crate) map_miss_service: AtomicU64,
    pub(crate) map_miss_characteristic: AtomicU64,
    pub(crate) peripheral_send_ok: AtomicU64,
    pub(crate) peripheral_send_error: AtomicU64,
    pub(crate) broadcast_send_ok: AtomicU64,
    pub(crate) broadcast_no_receiver: AtomicU64,
    pub(crate) consumer_lag_events: AtomicU64,
    pub(crate) consumer_lag_notifications: AtomicU64,
    pub(crate) consumer_closed: AtomicU64,
    pub(crate) receivers_started: AtomicU64,
    pub(crate) receivers_dropped: AtomicU64,
}
impl NotificationDiagnostics {
    pub(crate) fn register(peripheral: Uuid, service: Uuid, characteristic: Uuid) -> Arc<Self> {
        let target = Target(peripheral, service, characteristic);
        let counters = Arc::new(Self {
            epoch: NEXT_EPOCH.fetch_add(1, Relaxed),
            ..Self::default()
        });
        let mut targets = TARGETS.get_or_init(Default::default).write().unwrap();
        targets.retain(|(key, value)| *key != target && value.strong_count() != 0);
        targets.push((target, Arc::downgrade(&counters)));
        counters
    }

    /// Observe the SDK's existing consumer before it drops notification UUIDs.
    /// The caller must match this connection's target service and characteristic.
    pub fn observe_consumer(&self, data: &[u8]) {
        self.consumer.observe(data);
    }

    /// Only integer measurements; no target identity or notification data.
    /// Relaxed loads may span producer/consumer progress, including one packet's
    /// multi-counter update. Differences alone do not establish packet loss.
    pub fn snapshot(&self) -> Vec<(String, u64)> {
        let mut out = vec![("epoch".into(), self.epoch)];
        for (prefix, packets) in [
            ("callback_copy", &self.callback_copy),
            ("internal_dequeue", &self.internal_dequeue),
            ("read_divert", &self.read_divert),
            ("map_miss", &self.map_miss),
            ("peripheral_send", &self.peripheral_send),
            ("peripheral_dequeue", &self.peripheral_dequeue),
            ("broadcast_publish", &self.broadcast_publish),
            ("consumer", &self.consumer),
        ] {
            packets.snapshot(prefix, &mut out);
        }
        macro_rules! counters {
            ($($name:ident),* $(,)?) => {$({
                out.push((stringify!($name).into(), self.$name.load(Relaxed)));
            })*};
        }
        counters!(
            callback_total,
            callback_error,
            callback_value_none,
            callback_raw_bytes,
            callback_copy_len_mismatch,
            delegate_send_attempt,
            delegate_send_ok,
            delegate_send_error,
            map_miss_peripheral,
            map_miss_service,
            map_miss_characteristic,
            peripheral_send_ok,
            peripheral_send_error,
            broadcast_send_ok,
            broadcast_no_receiver,
            consumer_lag_events,
            consumer_lag_notifications,
            consumer_closed,
            receivers_started,
            receivers_dropped
        );
        out
    }
}

pub(crate) fn lookup(
    peripheral: Uuid,
    service: Uuid,
    characteristic: Uuid,
) -> Option<Arc<NotificationDiagnostics>> {
    let targets = TARGETS.get()?.read().ok()?;
    let target = Target(peripheral, service, characteristic);
    targets.iter().find(|(key, _)| *key == target)?.1.upgrade()
}

/// Tracks only the one already-existing receiver, never subscribes to anything.
pub(crate) struct ReceiverCounters(pub(crate) Option<Arc<NotificationDiagnostics>>);
impl ReceiverCounters {
    pub(crate) fn new(counters: Option<Arc<NotificationDiagnostics>>) -> Self {
        if let Some(counters) = &counters {
            counters.receivers_started.fetch_add(1, Relaxed);
        }
        Self(counters)
    }
}
impl Drop for ReceiverCounters {
    fn drop(&mut self) {
        if let Some(counters) = &self.0 {
            counters.receivers_dropped.fetch_add(1, Relaxed);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn value(counters: &NotificationDiagnostics, name: &str) -> u64 {
        counters
            .snapshot()
            .into_iter()
            .find(|(key, _)| key == name)
            .unwrap()
            .1
    }
    #[test]
    fn unmeasured_is_none_measured_zero_is_zero_and_targets_are_isolated() {
        let p = Uuid::from_u128(100);
        let s = Uuid::from_u128(101);
        let c = Uuid::from_u128(102);
        assert!(lookup(p, s, c).is_none());
        let counters = NotificationDiagnostics::register(p, s, c);
        assert_eq!(value(&counters, "callback_copy_bytes"), 0);
        assert!(lookup(p, s, c).is_some());
        assert!(lookup(Uuid::nil(), s, c).is_none());
        assert!(lookup(p, Uuid::nil(), c).is_none());
        assert!(lookup(p, s, Uuid::nil()).is_none());
        let second = NotificationDiagnostics::register(p, s, c);
        assert_ne!(value(&counters, "epoch"), value(&second, "epoch"));
        assert!(Arc::ptr_eq(&lookup(p, s, c).unwrap(), &second));
        drop(second);
        assert!(lookup(p, s, c).is_none());
    }
    #[test]
    fn all_layers_count_only_lengths_and_first_byte_classification() {
        let counters = NotificationDiagnostics::default();
        for stage in [
            &counters.callback_copy,
            &counters.internal_dequeue,
            &counters.peripheral_dequeue,
            &counters.broadcast_publish,
            &counters.consumer,
        ] {
            for data in [&[0, 13, 10, 123][..], &[1, 0][..], &[][..], &[0][..]] {
                stage.observe(data);
            }
        }
        for stage in [
            "callback_copy",
            "internal_dequeue",
            "peripheral_dequeue",
            "broadcast_publish",
            "consumer",
        ] {
            assert_eq!(value(&counters, &format!("{stage}_packets")), 4);
            assert_eq!(value(&counters, &format!("{stage}_bytes")), 7);
            assert_eq!(
                value(&counters, &format!("{stage}_leading_zero_packets")),
                2
            );
            assert_eq!(
                value(&counters, &format!("{stage}_leading_zero_raw_bytes")),
                5
            );
            assert_eq!(
                value(&counters, &format!("{stage}_leading_zero_payload_bytes")),
                3
            );
            assert_eq!(value(&counters, &format!("{stage}_empty_packets")), 1);
        }
    }
}
