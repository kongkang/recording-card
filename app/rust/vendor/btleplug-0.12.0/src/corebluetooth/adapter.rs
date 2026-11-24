use super::internal::{
    CoreBluetoothEvent, CoreBluetoothMessage, CoreBluetoothReply, CoreBluetoothReplyFuture,
    run_corebluetooth_thread,
};
use super::peripheral::{Peripheral, PeripheralId};
use crate::api::{Central, CentralEvent, CentralState, ScanFilter};
use crate::common::adapter_manager::AdapterManager;
use crate::{Error, Result};
use async_trait::async_trait;
use futures::channel::mpsc::{self, Sender};
use futures::sink::SinkExt;
use futures::stream::{Stream, StreamExt};
use log::*;
use objc2_core_bluetooth::CBManagerState;
use std::pin::Pin;
use std::sync::Arc;
use std::time::Duration;
use tokio::task;
use uuid::Uuid;

/// Implementation of [api::Central](crate::api::Central).
#[derive(Clone, Debug)]
pub struct Adapter {
    manager: Arc<AdapterManager<Peripheral>>,
    sender: Sender<CoreBluetoothMessage>,
}

fn get_central_state(state: CBManagerState) -> CentralState {
    match state {
        CBManagerState::PoweredOn => CentralState::PoweredOn,
        CBManagerState::PoweredOff => CentralState::PoweredOff,
        _ => CentralState::Unknown,
    }
}

fn handle_corebluetooth_event(
    manager: &Arc<AdapterManager<Peripheral>>,
    adapter_sender: &Sender<CoreBluetoothMessage>,
    msg: CoreBluetoothEvent,
) {
    match msg {
        CoreBluetoothEvent::DeviceDiscovered {
            uuid,
            local_name,
            advertisement_name,
            event_receiver,
        } => {
            let id = uuid.into();
            if let Some(existing) = manager.peripheral_mut(&id) {
                existing.value().update_name(local_name, advertisement_name);
                manager.emit(CentralEvent::DeviceUpdated(id));
                return;
            }
            let (prev_local, prev_adv) = manager
                .peripheral(&id)
                .map(|p| p.cached_names())
                .unwrap_or((None, None));
            manager.add_peripheral(Peripheral::new(
                uuid,
                local_name.filter(|s| !s.trim().is_empty()).or(prev_local),
                advertisement_name
                    .filter(|s| !s.trim().is_empty())
                    .or(prev_adv),
                Arc::downgrade(manager),
                event_receiver,
                adapter_sender.clone(),
            ));
            manager.emit(CentralEvent::DeviceDiscovered(id));
        }
        CoreBluetoothEvent::DeviceUpdated {
            uuid,
            local_name,
            advertisement_name,
        } => {
            let id = uuid.into();
            if let Some(entry) = manager.peripheral_mut(&id) {
                entry.value().update_name(local_name, advertisement_name);
                manager.emit(CentralEvent::DeviceUpdated(id));
            }
        }
        CoreBluetoothEvent::DeviceDisconnected { uuid } => {
            manager.emit(CentralEvent::DeviceDisconnected(uuid.into()));
        }
        CoreBluetoothEvent::DidUpdateState { state } => {
            let central_state = get_central_state(state);
            manager.emit(CentralEvent::StateUpdate(central_state));
        }
    }
}

impl Adapter {
    pub(crate) async fn new() -> Result<Self> {
        let (sender, mut receiver) = mpsc::channel(256);
        let adapter_sender = run_corebluetooth_thread(sender)?;
        // CoreBluetooth may emit `willRestoreState:` (restored peripherals) before
        // `centralManagerDidUpdateState:`. Buffer any pre-init events instead of failing.
        debug!("Waiting on adapter connect");
        let mut pre_init_events = Vec::new();
        loop {
            match receiver.next().await {
                Some(CoreBluetoothEvent::DidUpdateState { state: _ }) => break,
                Some(ev) => pre_init_events.push(ev),
                None => {
                    return Err(Error::Other(
                        "Adapter failed to connect.".to_string().into(),
                    ));
                }
            }
        }
        debug!("Adapter connected");
        let manager: Arc<AdapterManager<Peripheral>> = Arc::new(AdapterManager::default());
        for ev in pre_init_events {
            handle_corebluetooth_event(&manager, &adapter_sender, ev);
        }

        let manager_clone = manager.clone();
        let adapter_sender_clone = adapter_sender.clone();
        task::spawn(async move {
            while let Some(msg) = receiver.next().await {
                handle_corebluetooth_event(&manager_clone, &adapter_sender_clone, msg);
            }
        });

        Ok(Adapter {
            manager,
            sender: adapter_sender,
        })
    }

    pub async fn retrieve_peripherals(
        &self,
        identifiers: &[Uuid],
        services: &[Uuid],
    ) -> Result<Vec<Peripheral>> {
        let fut = CoreBluetoothReplyFuture::default();
        self.sender
            .to_owned()
            .send(CoreBluetoothMessage::RetrievePeripherals {
                identifiers: identifiers.to_vec(),
                services: services.to_vec(),
                future: fut.get_state_clone(),
            })
            .await?;

        let items = match fut.await {
            CoreBluetoothReply::PeripheralsMeta(items) => items,
            CoreBluetoothReply::Err(msg) => return Err(Error::RuntimeError(msg)),
            _ => return Err(Error::Other("Unexpected retrieve_peripherals reply".into())),
        };

        let mut out = Vec::with_capacity(items.len());
        let deadline = tokio::time::Instant::now() + Duration::from_millis(500);
        for (uuid, local_name, svcs) in items {
            let pid: PeripheralId = uuid.into();
            let mut found = self.manager.peripheral(&pid);
            while found.is_none() && tokio::time::Instant::now() < deadline {
                tokio::time::sleep(Duration::from_millis(5)).await;
                found = self.manager.peripheral(&pid);
            }
            if let Some(p) = found {
                p.merge_discovered_metadata(local_name, &svcs);
                out.push(p);
            }
        }
        Ok(out)
    }
}

#[async_trait]
impl Central for Adapter {
    type Peripheral = Peripheral;

    async fn events(&self) -> Result<Pin<Box<dyn Stream<Item = CentralEvent> + Send>>> {
        Ok(self.manager.event_stream())
    }

    async fn start_scan(&self, filter: ScanFilter) -> Result<()> {
        self.sender
            .to_owned()
            .send(CoreBluetoothMessage::StartScanning { filter })
            .await?;
        Ok(())
    }

    async fn stop_scan(&self) -> Result<()> {
        self.sender
            .to_owned()
            .send(CoreBluetoothMessage::StopScanning)
            .await?;
        Ok(())
    }

    async fn peripherals(&self) -> Result<Vec<Peripheral>> {
        Ok(self.manager.peripherals())
    }

    async fn retrieve_connected_peripherals(
        &self,
        services: &[uuid::Uuid],
    ) -> Result<Vec<Peripheral>> {
        if services.is_empty() {
            return Ok(Vec::new());
        }
        let fut = CoreBluetoothReplyFuture::default();
        self.sender
            .to_owned()
            .send(CoreBluetoothMessage::RetrieveConnectedPeripherals {
                services: services.to_vec(),
                future: fut.get_state_clone(),
            })
            .await?;
        let items = match fut.await {
            CoreBluetoothReply::PeripheralsMeta(items) => items,
            CoreBluetoothReply::Err(msg) => return Err(Error::RuntimeError(msg)),
            _ => return Ok(Vec::new()),
        };
        let mut out = Vec::with_capacity(items.len());
        for (uuid, local_name, svcs) in items {
            let pid: PeripheralId = uuid.into();
            let mut found = self.manager.peripheral(&pid);
            if found.is_none() {
                for _ in 0..10 {
                    tokio::time::sleep(std::time::Duration::from_millis(10)).await;
                    found = self.manager.peripheral(&pid);
                    if found.is_some() {
                        break;
                    }
                }
            }
            if let Some(p) = found {
                p.merge_discovered_metadata(local_name, &svcs);
                out.push(p);
            }
        }
        Ok(out)
    }

    async fn peripheral(&self, id: &PeripheralId) -> Result<Peripheral> {
        self.manager.peripheral(id).ok_or(Error::DeviceNotFound)
    }

    async fn add_peripheral(&self, _address: &PeripheralId) -> Result<Peripheral> {
        Err(Error::NotSupported(
            "Can't add a Peripheral from a PeripheralId".to_string(),
        ))
    }

    async fn clear_peripherals(&self) -> Result<()> {
        self.manager.clear_peripherals();
        Ok(())
    }

    async fn adapter_info(&self) -> Result<String> {
        // TODO: Get information about the adapter.
        Ok("CoreBluetooth".to_string())
    }

    async fn adapter_state(&self) -> Result<CentralState> {
        let fut = CoreBluetoothReplyFuture::default();
        self.sender
            .to_owned()
            .send(CoreBluetoothMessage::GetAdapterState {
                future: fut.get_state_clone(),
            })
            .await?;

        match fut.await {
            CoreBluetoothReply::AdapterState(state) => {
                let central_state = get_central_state(state);
                return Ok(central_state.clone());
            }
            _ => panic!("Shouldn't get anything but a AdapterState!"),
        }
    }
}
