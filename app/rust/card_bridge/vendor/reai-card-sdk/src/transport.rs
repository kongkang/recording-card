use std::{pin::Pin, sync::Arc};

use async_trait::async_trait;
use futures::Stream;

use crate::Result;

pub type NotificationStream = Pin<Box<dyn Stream<Item = Result<Vec<u8>>> + Send>>;

/// A narrow BLE transport seam. It permits deterministic protocol tests without Bluetooth hardware.
#[async_trait]
pub trait BleTransport: Send + Sync {
    async fn write(&self, bytes: &[u8]) -> Result<()>;
    async fn notifications(&self) -> Result<NotificationStream>;
    async fn disconnect(&self) -> Result<()>;

    /// Optional, non-fenced integer counters. None means unmeasured, not zero.
    fn notification_diagnostics(&self) -> Option<serde_json::Value> {
        None
    }
}

pub type SharedTransport = Arc<dyn BleTransport>;

#[cfg(test)]
mod diagnostics_tests {
    use super::*;
    struct Fake;
    #[async_trait]
    impl BleTransport for Fake {
        async fn write(&self, _: &[u8]) -> Result<()> {
            Ok(())
        }
        async fn notifications(&self) -> Result<NotificationStream> {
            Ok(Box::pin(futures::stream::empty()))
        }
        async fn disconnect(&self) -> Result<()> {
            Ok(())
        }
    }
    #[test]
    fn fake_notification_diagnostics_are_unmeasured_not_zero() {
        let transport: SharedTransport = Arc::new(Fake);
        assert!(transport.notification_diagnostics().is_none());
    }
}
