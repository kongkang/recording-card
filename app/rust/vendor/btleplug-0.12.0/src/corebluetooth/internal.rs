// btleplug Source Code File
//
// Copyright 2020 Nonpolynomial Labs LLC. All rights reserved.
//
// Licensed under the BSD 3-Clause license. See LICENSE file in the project root
// for full license information.
//
// For more info on handling CoreBluetooth Managers (and possibly having
// multiple), see https://forums.developer.apple.com/thread/20810

use super::{
    central_delegate::{CentralDelegate, CentralDelegateEvent},
    ffi,
    future::{BtlePlugFuture, BtlePlugFutureStateShared},
    utils::{
        core_bluetooth::{cbuuid_to_uuid, uuid_to_cbuuid},
        nsuuid_to_uuid,
    },
};
use crate::Error;
use crate::api::{CharPropFlags, Characteristic, Descriptor, ScanFilter, Service, WriteType};
use futures::channel::mpsc::{self, Receiver, Sender, UnboundedReceiver};
use futures::future::FutureExt;
use futures::select;
use futures::sink::SinkExt;
use futures::stream::{Fuse, StreamExt};
use log::{error, trace, warn};
use objc2::{ClassType, msg_send_id};
use objc2::{rc::Retained, runtime::AnyObject};
use objc2_core_bluetooth::{
    CBCentralManager, CBCentralManagerScanOptionAllowDuplicatesKey, CBCharacteristic,
    CBCharacteristicProperties, CBCharacteristicWriteType, CBDescriptor, CBManager,
    CBManagerAuthorization, CBManagerState, CBPeripheral, CBPeripheralState, CBService, CBUUID,
};
use objc2_foundation::{NSArray, NSData, NSMutableDictionary, NSNumber};
use std::{
    collections::{BTreeSet, HashMap, VecDeque},
    ffi::{CString, c_void},
    fmt::{self, Debug, Formatter},
    ops::Deref,
    sync::{Arc, Mutex},
    thread,
    time::Duration,
};
use tokio::runtime;
use uuid::Uuid;

struct DescriptorInternal {
    pub descriptor: Retained<CBDescriptor>,
    pub uuid: Uuid,
    pub read_future_state: VecDeque<CoreBluetoothReplyStateShared>,
    pub write_future_state: VecDeque<CoreBluetoothReplyStateShared>,
}

impl DescriptorInternal {
    pub fn new(descriptor: Retained<CBDescriptor>) -> Self {
        let raw_uuid = unsafe { descriptor.UUID() };
        let uuid = cbuuid_to_uuid(&raw_uuid);
        Self {
            descriptor,
            uuid,
            read_future_state: VecDeque::with_capacity(10),
            write_future_state: VecDeque::with_capacity(10),
        }
    }
}

struct CharacteristicInternal {
    pub characteristic: Retained<CBCharacteristic>,
    pub uuid: Uuid,
    pub properties: CharPropFlags,
    pub descriptors: HashMap<Uuid, DescriptorInternal>,
    pub read_future_state: VecDeque<CoreBluetoothReplyStateShared>,
    pub write_future_state: VecDeque<CoreBluetoothReplyStateShared>,
    pub subscribe_future_state: VecDeque<CoreBluetoothReplyStateShared>,
    pub unsubscribe_future_state: VecDeque<CoreBluetoothReplyStateShared>,
    pub discovered: bool,
}

impl Debug for CharacteristicInternal {
    fn fmt(&self, f: &mut Formatter) -> fmt::Result {
        f.debug_struct("CBCharacteristic")
            .field("characteristic", self.characteristic.deref())
            .field("uuid", &self.uuid)
            .field("properties", &self.properties)
            .field("read_future_state", &self.read_future_state)
            .field("write_future_state", &self.write_future_state)
            .field("subscribe_future_state", &self.subscribe_future_state)
            .field("unsubscribe_future_state", &self.unsubscribe_future_state)
            .finish()
    }
}

impl CharacteristicInternal {
    pub fn new(characteristic: Retained<CBCharacteristic>) -> Self {
        let properties = CharacteristicInternal::form_flags(&*characteristic);
        let raw_uuid = unsafe { characteristic.UUID() };
        let uuid = cbuuid_to_uuid(&raw_uuid);
        let descriptors_arr = unsafe { characteristic.descriptors() };
        let mut descriptors = HashMap::new();
        if let Some(descriptors_arr) = descriptors_arr {
            for d in descriptors_arr {
                let descriptor = DescriptorInternal::new(d);
                descriptors.insert(descriptor.uuid, descriptor);
            }
        }
        Self {
            characteristic,
            uuid,
            properties,
            descriptors,
            read_future_state: VecDeque::with_capacity(10),
            write_future_state: VecDeque::with_capacity(10),
            subscribe_future_state: VecDeque::with_capacity(10),
            unsubscribe_future_state: VecDeque::with_capacity(10),
            discovered: false,
        }
    }

    fn form_flags(characteristic: &CBCharacteristic) -> CharPropFlags {
        let flags = unsafe { characteristic.properties() };
        let mut v = CharPropFlags::default();
        if flags.contains(CBCharacteristicProperties::CBCharacteristicPropertyBroadcast) {
            v |= CharPropFlags::BROADCAST;
        }
        if flags.contains(CBCharacteristicProperties::CBCharacteristicPropertyRead) {
            v |= CharPropFlags::READ;
        }
        if flags.contains(CBCharacteristicProperties::CBCharacteristicPropertyWriteWithoutResponse)
        {
            v |= CharPropFlags::WRITE_WITHOUT_RESPONSE;
        }
        if flags.contains(CBCharacteristicProperties::CBCharacteristicPropertyWrite) {
            v |= CharPropFlags::WRITE;
        }
        if flags.contains(CBCharacteristicProperties::CBCharacteristicPropertyNotify) {
            v |= CharPropFlags::NOTIFY;
        }
        if flags.contains(CBCharacteristicProperties::CBCharacteristicPropertyIndicate) {
            v |= CharPropFlags::INDICATE;
        }
        if flags
            .contains(CBCharacteristicProperties::CBCharacteristicPropertyAuthenticatedSignedWrites)
        {
            v |= CharPropFlags::AUTHENTICATED_SIGNED_WRITES;
        }
        trace!("Flags: {:?}", v);
        v
    }
}

struct PendingCbWriteItem {
    characteristic: Retained<CBCharacteristic>,
    data: Retained<NSData>,
    fut: CoreBluetoothReplyStateShared,
}

struct CbWriteQueueInner {
    peripheral: Retained<CBPeripheral>,
    pending: VecDeque<PendingCbWriteItem>,
    disconnected: bool,
}

// SAFETY: Objective-C `Retained` retain/release is atomic, and all CoreBluetooth
// methods (`state`, `canSendWriteWithoutResponse`, `writeValue_forCharacteristic_type`)
// are invoked solely inside `drain_on_cb_queue` on the `"CBqueue"` serial queue.
unsafe impl Send for CbWriteQueueInner {}

struct CbWriteWithoutResponseQueue {
    inner: Mutex<CbWriteQueueInner>,
}

impl CbWriteWithoutResponseQueue {
    fn new(peripheral: Retained<CBPeripheral>) -> Self {
        Self {
            inner: Mutex::new(CbWriteQueueInner {
                peripheral,
                pending: VecDeque::new(),
                disconnected: false,
            }),
        }
    }

    fn enqueue(&self, item: PendingCbWriteItem) {
        let mut guard = self.inner.lock().unwrap();
        if guard.disconnected {
            item.fut
                .lock()
                .unwrap()
                .set_reply(CoreBluetoothReply::Err("Device disconnected".into()));
            return;
        }
        guard.pending.push_back(item);
    }

    fn has_pending(&self) -> bool {
        !self.inner.lock().unwrap().pending.is_empty()
    }

    fn fail_all_disconnected(&self, reason: &str) {
        let mut guard = self.inner.lock().unwrap();
        guard.disconnected = true;
        while let Some(item) = guard.pending.pop_front() {
            item.fut
                .lock()
                .unwrap()
                .set_reply(CoreBluetoothReply::Err(reason.to_string()));
        }
    }

    fn drain_on_cb_queue(&self) {
        loop {
            let next = {
                let mut guard = self.inner.lock().unwrap();
                if guard.disconnected {
                    while let Some(item) = guard.pending.pop_front() {
                        item.fut
                            .lock()
                            .unwrap()
                            .set_reply(CoreBluetoothReply::Err("Device disconnected".into()));
                    }
                    return;
                }
                if guard.pending.is_empty() {
                    return;
                }
                let state = unsafe { guard.peripheral.state() };
                if state != CBPeripheralState::Connected {
                    guard.disconnected = true;
                    while let Some(item) = guard.pending.pop_front() {
                        item.fut
                            .lock()
                            .unwrap()
                            .set_reply(CoreBluetoothReply::Err("Device disconnected".into()));
                    }
                    return;
                }
                if !unsafe { guard.peripheral.canSendWriteWithoutResponse() } {
                    return;
                }
                guard
                    .pending
                    .pop_front()
                    .map(|item| (guard.peripheral.clone(), item))
            };
            let Some((peripheral, item)) = next else {
                return;
            };
            unsafe {
                peripheral.writeValue_forCharacteristic_type(
                    &item.data,
                    &item.characteristic,
                    CBCharacteristicWriteType::CBCharacteristicWriteWithoutResponse,
                );
            }
            item.fut.lock().unwrap().set_reply(CoreBluetoothReply::Ok);
        }
    }
}

unsafe extern "C" fn drain_cb_write_queue_trampoline(ctx: *mut c_void) {
    if ctx.is_null() {
        return;
    }
    // SAFETY: `ctx` comes from `Arc::into_raw` when dispatching onto `cb_queue`.
    let queue = unsafe { Arc::from_raw(ctx as *const CbWriteWithoutResponseQueue) };
    queue.drain_on_cb_queue();
}

#[derive(Clone, Debug)]
pub enum CoreBluetoothReply {
    AdapterState(CBManagerState),
    ReadResult(Vec<u8>),
    ReadRssi(i16),
    Connected,
    ServicesDiscovered(BTreeSet<Service>),
    State(CBPeripheralState),
    Ok,
    Err(String),
}

#[derive(Debug)]
pub enum PeripheralEventInternal {
    Disconnected,
    Notification(Uuid, Uuid, Vec<u8>),
    ManufacturerData(u16, Vec<u8>, i16),
    ServiceData(HashMap<Uuid, Vec<u8>>, i16),
    Services(Vec<Uuid>, i16),
    ServicesModified,
    TxPowerLevel(i16),
    RssiRead(i16),
}

pub type CoreBluetoothReplyStateShared = BtlePlugFutureStateShared<CoreBluetoothReply>;
pub type CoreBluetoothReplyFuture = BtlePlugFuture<CoreBluetoothReply>;

struct ServiceInternal {
    cbservice: Retained<CBService>,
    characteristics: HashMap<Uuid, CharacteristicInternal>,
    pub discovered: bool,
}

struct PeripheralInternal {
    pub peripheral: Retained<CBPeripheral>,
    services: HashMap<Uuid, ServiceInternal>,
    pub event_sender: Sender<PeripheralEventInternal>,
    pub disconnected_future_state: Option<CoreBluetoothReplyStateShared>,
    pub connected_future_state: Option<CoreBluetoothReplyStateShared>,
    pub services_discovered_future_state: Option<CoreBluetoothReplyStateShared>,
    pub read_rssi_future_state: VecDeque<CoreBluetoothReplyStateShared>,
    pub cb_write_queue: Arc<CbWriteWithoutResponseQueue>,
}

impl Debug for PeripheralInternal {
    fn fmt(&self, f: &mut Formatter) -> fmt::Result {
        f.debug_struct("CBPeripheral")
            .field("peripheral", self.peripheral.deref())
            .field(
                "services",
                &self
                    .services
                    .iter()
                    .map(|(service_uuid, service)| (service_uuid, service.characteristics.len()))
                    .collect::<HashMap<_, _>>(),
            )
            .field("event_sender", &self.event_sender)
            .field("connected_future_state", &self.connected_future_state)
            .field(
                "services_discovered_future_state",
                &self.services_discovered_future_state,
            )
            .finish()
    }
}

impl PeripheralInternal {
    pub fn new(
        peripheral: Retained<CBPeripheral>,
        event_sender: Sender<PeripheralEventInternal>,
    ) -> Self {
        let cb_write_queue = Arc::new(CbWriteWithoutResponseQueue::new(peripheral.clone()));
        Self {
            peripheral,
            services: HashMap::new(),
            event_sender,
            connected_future_state: None,
            disconnected_future_state: None,
            services_discovered_future_state: None,
            read_rssi_future_state: VecDeque::with_capacity(4),
            cb_write_queue,
        }
    }

    pub fn set_characteristics(
        &mut self,
        service_uuid: Uuid,
        characteristics: HashMap<Uuid, Retained<CBCharacteristic>>,
    ) {
        let Some(service) = self.services.get_mut(&service_uuid) else {
            return;
        };
        for (characteristic_uuid, cb_characteristic) in characteristics {
            if let Some(existing) = service.characteristics.get_mut(&characteristic_uuid) {
                // Update the CB object reference and properties, but preserve
                // in-flight future state and already-discovered descriptors to
                // avoid dropping pending operations during late re-discovery
                // events (see issue #167).
                existing.properties = CharacteristicInternal::form_flags(&*cb_characteristic);
                existing.characteristic = cb_characteristic;
            } else {
                service.characteristics.insert(
                    characteristic_uuid,
                    CharacteristicInternal::new(cb_characteristic),
                );
            }
        }
        if service.characteristics.is_empty() {
            service.discovered = true;
            self.check_discovered();
        }
    }

    pub fn set_characteristic_descriptors(
        &mut self,
        service_uuid: Uuid,
        characteristic_uuid: Uuid,
        descriptors: HashMap<Uuid, Retained<CBDescriptor>>,
    ) {
        let Some(service) = self.services.get_mut(&service_uuid) else {
            return;
        };
        let Some(characteristic) = service.characteristics.get_mut(&characteristic_uuid) else {
            return;
        };
        for (descriptor_uuid, cb_descriptor) in descriptors {
            if let Some(existing) = characteristic.descriptors.get_mut(&descriptor_uuid) {
                // Update the CB object reference but preserve in-flight future
                // state to avoid dropping pending operations during late
                // re-discovery events (see issue #167).
                existing.descriptor = cb_descriptor;
            } else {
                characteristic
                    .descriptors
                    .insert(descriptor_uuid, DescriptorInternal::new(cb_descriptor));
            }
        }
        characteristic.discovered = true;

        if !service
            .characteristics
            .values()
            .any(|characteristic| !characteristic.discovered)
        {
            service.discovered = true;
            self.check_discovered()
        }
    }

    fn check_discovered(&mut self) {
        // It's time for QUESTIONABLE ASSUMPTIONS.
        //
        // For sake of being lazy, we don't want to fire device connection until
        // we have all of our services and characteristics. We assume that
        // set_characteristics should be called once for every entry in the
        // service map. Once that's done, we're filled out enough and can send
        // back a ServicesDiscovered reply to the waiting future with all of
        // the characteristic info in it.
        if !self.services.values().any(|service| !service.discovered) {
            let Some(fut) = self.services_discovered_future_state.take() else {
                return;
            };
            let services = self
                .services
                .iter()
                .map(|(&service_uuid, service)| Service {
                    uuid: service_uuid,
                    primary: unsafe { service.cbservice.isPrimary() },
                    characteristics: service
                        .characteristics
                        .iter()
                        .map(|(&characteristic_uuid, characteristic)| {
                            let descriptors = characteristic
                                .descriptors
                                .iter()
                                .map(|(&descriptor_uuid, _)| Descriptor {
                                    uuid: descriptor_uuid,
                                    service_uuid,
                                    characteristic_uuid,
                                })
                                .collect();
                            Characteristic {
                                uuid: characteristic_uuid,
                                service_uuid,
                                descriptors,
                                properties: characteristic.properties,
                            }
                        })
                        .collect(),
                })
                .collect();
            fut.lock()
                .unwrap()
                .set_reply(CoreBluetoothReply::ServicesDiscovered(services));
        }
    }

    pub fn confirm_disconnect(&mut self) {
        // Fulfill the disconnected future, if there is one.
        // There might not be a future if the device disconnects unexpectedly.
        if let Some(future) = self.disconnected_future_state.take() {
            future.lock().unwrap().set_reply(CoreBluetoothReply::Ok)
        }

        // Fulfill pending connect / discovery / RSSI futures
        let error = CoreBluetoothReply::Err(String::from("Device disconnected"));
        if let Some(future) = self.connected_future_state.take() {
            future.lock().unwrap().set_reply(error.clone());
        }
        if let Some(future) = self.services_discovered_future_state.take() {
            future.lock().unwrap().set_reply(error.clone());
        }
        for state in self.read_rssi_future_state.drain(..) {
            state.lock().unwrap().set_reply(error.clone());
        }

        // Fulfill pending write-without-response futures
        self.cb_write_queue
            .fail_all_disconnected("Device disconnected");

        // Fulfill all pending characteristic & descriptor futures
        for (_, service) in self.services.iter_mut() {
            for (_, characteristic) in service.characteristics.iter_mut() {
                for state in characteristic.read_future_state.drain(..) {
                    state.lock().unwrap().set_reply(error.clone());
                }
                for state in characteristic.write_future_state.drain(..) {
                    state.lock().unwrap().set_reply(error.clone());
                }
                for state in characteristic.subscribe_future_state.drain(..) {
                    state.lock().unwrap().set_reply(error.clone());
                }
                for state in characteristic.unsubscribe_future_state.drain(..) {
                    state.lock().unwrap().set_reply(error.clone());
                }
                for (_, descriptor) in characteristic.descriptors.iter_mut() {
                    for state in descriptor.read_future_state.drain(..) {
                        state.lock().unwrap().set_reply(error.clone());
                    }
                    for state in descriptor.write_future_state.drain(..) {
                        state.lock().unwrap().set_reply(error.clone());
                    }
                }
            }
        }
    }
}

// All of CoreBluetooth is basically async. It's all just waiting on delegate
// events/callbacks. Therefore, we should be able to round up all of our wacky
// ass mut *Object values, keep them in a single struct, in a single thread, and
// call it good. Right?
struct CoreBluetoothInternal {
    manager: Retained<CBCentralManager>,
    cb_queue: ffi::dispatch_queue_t,
    delegate: Retained<CentralDelegate>,
    // Map of identifiers to object pointers
    peripherals: HashMap<Uuid, PeripheralInternal>,
    delegate_receiver: Fuse<UnboundedReceiver<CentralDelegateEvent>>,
    // Out in the world beyond CoreBluetooth, we'll be async, so just
    // task::block this when sending even though it'll never actually block.
    event_sender: Sender<CoreBluetoothEvent>,
    message_receiver: Fuse<Receiver<CoreBluetoothMessage>>,
}

impl Debug for CoreBluetoothInternal {
    fn fmt(&self, f: &mut Formatter) -> fmt::Result {
        f.debug_struct("CoreBluetoothInternal")
            .field("manager", self.manager.deref())
            .field("delegate", self.delegate.deref())
            .field("peripherals", &self.peripherals)
            .field("delegate_receiver", &self.delegate_receiver)
            .field("event_sender", &self.event_sender)
            .field("message_receiver", &self.message_receiver)
            .finish()
    }
}

#[derive(Debug)]
pub enum CoreBluetoothMessage {
    GetAdapterState {
        future: CoreBluetoothReplyStateShared,
    },
    StartScanning {
        filter: ScanFilter,
    },
    StopScanning,
    ConnectDevice {
        peripheral_uuid: Uuid,
        future: CoreBluetoothReplyStateShared,
    },
    DisconnectDevice {
        peripheral_uuid: Uuid,
        future: CoreBluetoothReplyStateShared,
    },
    ReadValue {
        peripheral_uuid: Uuid,
        service_uuid: Uuid,
        characteristic_uuid: Uuid,
        future: CoreBluetoothReplyStateShared,
    },
    WriteValue {
        peripheral_uuid: Uuid,
        service_uuid: Uuid,
        characteristic_uuid: Uuid,
        data: Vec<u8>,
        write_type: WriteType,
        future: CoreBluetoothReplyStateShared,
    },
    Subscribe {
        peripheral_uuid: Uuid,
        service_uuid: Uuid,
        characteristic_uuid: Uuid,
        future: CoreBluetoothReplyStateShared,
    },
    Unsubscribe {
        peripheral_uuid: Uuid,
        service_uuid: Uuid,
        characteristic_uuid: Uuid,
        future: CoreBluetoothReplyStateShared,
    },
    IsConnected {
        peripheral_uuid: Uuid,
        future: CoreBluetoothReplyStateShared,
    },
    ReadDescriptorValue {
        peripheral_uuid: Uuid,
        service_uuid: Uuid,
        characteristic_uuid: Uuid,
        descriptor_uuid: Uuid,
        future: CoreBluetoothReplyStateShared,
    },
    WriteDescriptorValue {
        peripheral_uuid: Uuid,
        service_uuid: Uuid,
        characteristic_uuid: Uuid,
        descriptor_uuid: Uuid,
        data: Vec<u8>,
        future: CoreBluetoothReplyStateShared,
    },
    DiscoverServices {
        peripheral_uuid: Uuid,
        future: CoreBluetoothReplyStateShared,
    },
    ReadRssi {
        peripheral_uuid: Uuid,
        future: CoreBluetoothReplyStateShared,
    },
}

#[derive(Debug)]
pub enum CoreBluetoothEvent {
    DidUpdateState {
        state: CBManagerState,
    },
    DeviceDiscovered {
        uuid: Uuid,
        local_name: Option<String>,
        advertisement_name: Option<String>,
        event_receiver: Receiver<PeripheralEventInternal>,
    },
    DeviceUpdated {
        uuid: Uuid,
        local_name: Option<String>,
        advertisement_name: Option<String>,
    },
    DeviceDisconnected {
        uuid: Uuid,
    },
}

impl CoreBluetoothInternal {
    pub fn new(
        message_receiver: Receiver<CoreBluetoothMessage>,
        event_sender: Sender<CoreBluetoothEvent>,
    ) -> Self {
        let (sender, receiver) = mpsc::unbounded::<CentralDelegateEvent>();
        let delegate = CentralDelegate::new(sender);

        let label = CString::new("CBqueue").unwrap();
        let cb_queue =
            unsafe { ffi::dispatch_queue_create(label.as_ptr(), ffi::DISPATCH_QUEUE_SERIAL) };
        let queue: *mut AnyObject = cb_queue.cast();

        let manager = unsafe {
            msg_send_id![CBCentralManager::alloc(), initWithDelegate: &*delegate, queue: queue]
        };

        Self {
            manager,
            cb_queue,
            peripherals: HashMap::new(),
            delegate_receiver: receiver.fuse(),
            event_sender,
            message_receiver: message_receiver.fuse(),
            delegate,
        }
    }

    fn schedule_cb_write_drain(&self, peripheral_uuid: Uuid) {
        if let Some(p) = self.peripherals.get(&peripheral_uuid) {
            if p.cb_write_queue.has_pending() {
                let ptr = Arc::into_raw(p.cb_write_queue.clone()) as *mut c_void;
                unsafe {
                    ffi::dispatch_async_f(self.cb_queue, ptr, drain_cb_write_queue_trampoline);
                }
            }
        }
    }

    fn schedule_all_pending_cb_write_drains(&self) {
        for p in self.peripherals.values() {
            if p.cb_write_queue.has_pending() {
                let ptr = Arc::into_raw(p.cb_write_queue.clone()) as *mut c_void;
                unsafe {
                    ffi::dispatch_async_f(self.cb_queue, ptr, drain_cb_write_queue_trampoline);
                }
            }
        }
    }

    async fn dispatch_event(&self, event: CoreBluetoothEvent) {
        let mut s = self.event_sender.clone();
        if let Err(e) = s.send(event).await {
            error!("Error dispatching event: {:?}", e);
        }
    }

    async fn on_manufacturer_data(
        &mut self,
        peripheral_uuid: Uuid,
        manufacturer_id: u16,
        manufacturer_data: Vec<u8>,
        rssi: i16,
    ) {
        trace!(
            "Got manufacturer data advertisement! {}: {:?}",
            manufacturer_id, manufacturer_data
        );
        if let Some(p) = self.peripherals.get_mut(&peripheral_uuid) {
            if let Err(e) = p
                .event_sender
                .send(PeripheralEventInternal::ManufacturerData(
                    manufacturer_id,
                    manufacturer_data,
                    rssi,
                ))
                .await
            {
                error!("Error sending notification event: {}", e);
            }
        }
    }

    async fn on_service_data(
        &mut self,
        peripheral_uuid: Uuid,
        service_data: HashMap<Uuid, Vec<u8>>,
        rssi: i16,
    ) {
        trace!("Got service data advertisement! {:?}", service_data);
        if let Some(p) = self.peripherals.get_mut(&peripheral_uuid) {
            if let Err(e) = p
                .event_sender
                .send(PeripheralEventInternal::ServiceData(service_data, rssi))
                .await
            {
                error!("Error sending notification event: {}", e);
            }
        }
    }

    async fn on_services(&mut self, peripheral_uuid: Uuid, services: Vec<Uuid>, rssi: i16) {
        trace!("Got service advertisement! {:?}", services);
        if let Some(p) = self.peripherals.get_mut(&peripheral_uuid) {
            if let Err(e) = p
                .event_sender
                .send(PeripheralEventInternal::Services(services, rssi))
                .await
            {
                error!("Error sending notification event: {}", e);
            }
        }
    }

    async fn on_services_modified(&mut self, peripheral_uuid: Uuid) {
        trace!(
            "Peripheral modified services and must be rediscovered! {:?}",
            peripheral_uuid
        );
        if let Some(p) = self.peripherals.get_mut(&peripheral_uuid) {
            p.services.clear();
            if let Err(e) = p
                .event_sender
                .send(PeripheralEventInternal::ServicesModified)
                .await
            {
                error!("Error sending notification event: {}", e);
            }
        }
    }

    async fn on_discovered_peripheral(
        &mut self,
        peripheral: Retained<CBPeripheral>,
        advertisement_name: Option<String>,
    ) {
        let id = unsafe { peripheral.identifier() };
        let uuid = nsuuid_to_uuid(&id);
        let peripheral_name = unsafe { peripheral.name() };
        let local_name = advertisement_name
            .clone()
            .filter(|s| !s.trim().is_empty())
            .or_else(|| peripheral_name.map(|n| n.to_string()));

        if self.peripherals.contains_key(&uuid) {
            if local_name.is_some() || advertisement_name.is_some() {
                self.dispatch_event(CoreBluetoothEvent::DeviceUpdated {
                    uuid,
                    local_name,
                    advertisement_name,
                })
                .await;
            }
        } else {
            // Create our channels
            let (event_sender, event_receiver) = mpsc::channel(256);
            self.peripherals
                .insert(uuid, PeripheralInternal::new(peripheral, event_sender));
            self.dispatch_event(CoreBluetoothEvent::DeviceDiscovered {
                uuid,
                local_name,
                advertisement_name,
                event_receiver,
            })
            .await;
        }
    }

    fn on_discovered_services(
        &mut self,
        peripheral_uuid: Uuid,
        service_map: HashMap<Uuid, Retained<CBService>>,
    ) {
        trace!("Found services!");
        for id in service_map.keys() {
            trace!("{}", id);
        }
        if let Some(p) = self.peripherals.get_mut(&peripheral_uuid) {
            let services = service_map
                .into_iter()
                .map(|(service_uuid, cbservice)| {
                    (
                        service_uuid,
                        ServiceInternal {
                            cbservice,
                            characteristics: HashMap::new(),
                            discovered: false,
                        },
                    )
                })
                .collect();
            p.services = services;
        }
    }

    fn on_discovered_characteristics(
        &mut self,
        peripheral_uuid: Uuid,
        service_uuid: Uuid,
        characteristics: HashMap<Uuid, Retained<CBCharacteristic>>,
    ) {
        trace!(
            "Found characteristics for peripheral {} service {}:",
            peripheral_uuid, service_uuid
        );
        for id in characteristics.keys() {
            trace!("{}", id);
        }
        if let Some(p) = self.peripherals.get_mut(&peripheral_uuid) {
            p.set_characteristics(service_uuid, characteristics);
        }
    }

    fn on_discovered_characteristic_descriptors(
        &mut self,
        peripheral_uuid: Uuid,
        service_uuid: Uuid,
        characteristic_uuid: Uuid,
        descriptors: HashMap<Uuid, Retained<CBDescriptor>>,
    ) {
        trace!(
            "Found descriptors for peripheral {} service {} characteristic {}:",
            peripheral_uuid, service_uuid, characteristic_uuid,
        );
        for id in descriptors.keys() {
            trace!("{}", id);
        }
        if let Some(p) = self.peripherals.get_mut(&peripheral_uuid) {
            p.set_characteristic_descriptors(service_uuid, characteristic_uuid, descriptors);
        }
    }

    fn on_peripheral_connect(&mut self, peripheral_uuid: Uuid) {
        if let Some(peripheral) = self.peripherals.get_mut(&peripheral_uuid) {
            if let Some(fut) = peripheral.connected_future_state.take() {
                fut.lock()
                    .unwrap()
                    .set_reply(CoreBluetoothReply::Connected);
            }
        }
    }

    async fn on_peripheral_connection_failed(
        &mut self,
        peripheral_uuid: Uuid,
        error_description: Option<String>,
    ) {
        trace!("Got connection fail event!");
        let error = error_description.unwrap_or(String::from("Connection failed"));
        let cancelled = if let Some(peripheral) = self.peripherals.get_mut(&peripheral_uuid) {
            if let Some(fut) = peripheral.connected_future_state.take() {
                fut.lock()
                    .unwrap()
                    .set_reply(CoreBluetoothReply::Err(error));
            }
            if let Some(dfut) = peripheral.disconnected_future_state.take() {
                dfut.lock().unwrap().set_reply(CoreBluetoothReply::Ok);
                true
            } else {
                false
            }
        } else {
            false
        };
        if cancelled {
            if let Some(mut p) = self.peripherals.remove(&peripheral_uuid) {
                p.confirm_disconnect();
            }
            self.dispatch_event(CoreBluetoothEvent::DeviceDisconnected {
                uuid: peripheral_uuid,
            })
            .await;
        }
    }

    async fn on_adapter_powered_off(&mut self) {
        warn!("Adapter powered off, canceling all pending operations");
        let peripheral_uuids: Vec<Uuid> = self.peripherals.keys().cloned().collect();
        for uuid in peripheral_uuids {
            if let Some(p) = self.peripherals.get_mut(&uuid) {
                if let Err(e) = p
                    .event_sender
                    .send(PeripheralEventInternal::Disconnected)
                    .await
                {
                    error!("Error sending disconnect event for {}: {}", uuid, e);
                }
            }
            if let Some(p) = self.peripherals.get_mut(&uuid) {
                p.confirm_disconnect();
            }
            self.dispatch_event(CoreBluetoothEvent::DeviceDisconnected { uuid })
                .await;
        }
        self.peripherals.clear();
    }

    async fn on_peripheral_disconnect(&mut self, peripheral_uuid: Uuid) {
        trace!("Got disconnect event!");
        if let Some(p) = self.peripherals.get_mut(&peripheral_uuid) {
            if let Err(e) = p
                .event_sender
                .send(PeripheralEventInternal::Disconnected)
                .await
            {
                error!("Error sending notification event: {}", e);
            }
        }
        // Unlike connect, we'll want to fulfill our disconnect future here, which means grabbing
        // our peripheral and having it fire, then dropping it and dispatching our event.
        if let Some(mut p) = self.peripherals.remove(&peripheral_uuid) {
            p.confirm_disconnect();
            self.dispatch_event(CoreBluetoothEvent::DeviceDisconnected {
                uuid: peripheral_uuid,
            })
            .await;
        }
    }

    /// Get the CBCharacteristic for the given characteristic of the given peripheral, if it exists.
    fn get_characteristic(
        &mut self,
        peripheral_uuid: Uuid,
        service_uuid: Uuid,
        characteristic_uuid: Uuid,
    ) -> Option<&mut CharacteristicInternal> {
        self.peripherals
            .get_mut(&peripheral_uuid)?
            .services
            .get_mut(&service_uuid)?
            .characteristics
            .get_mut(&characteristic_uuid)
    }

    /// Get the CBDescriptor for the given descriptor of the given peripheral, if it exists.
    fn get_descriptor(
        &mut self,
        peripheral_uuid: Uuid,
        service_uuid: Uuid,
        characteristic_uuid: Uuid,
        descriptor_uuid: Uuid,
    ) -> Option<&mut DescriptorInternal> {
        self.get_characteristic(peripheral_uuid, service_uuid, characteristic_uuid)?
            .descriptors
            .get_mut(&descriptor_uuid)
    }

    fn on_characteristic_subscribed(
        &mut self,
        peripheral_uuid: Uuid,
        service_uuid: Uuid,
        characteristic_uuid: Uuid,
    ) {
        if let Some(characteristic) =
            self.get_characteristic(peripheral_uuid, service_uuid, characteristic_uuid)
        {
            trace!("Got subscribed event!");
            if let Some(state) = characteristic.subscribe_future_state.pop_back() {
                state.lock().unwrap().set_reply(CoreBluetoothReply::Ok);
            }
        }
    }

    fn on_characteristic_unsubscribed(
        &mut self,
        peripheral_uuid: Uuid,
        service_uuid: Uuid,
        characteristic_uuid: Uuid,
    ) {
        if let Some(characteristic) =
            self.get_characteristic(peripheral_uuid, service_uuid, characteristic_uuid)
        {
            trace!("Got unsubscribed event!");
            if let Some(state) = characteristic.unsubscribe_future_state.pop_back() {
                state.lock().unwrap().set_reply(CoreBluetoothReply::Ok);
            }
        }
    }

    fn on_characteristic_subscribe_failed(
        &mut self,
        peripheral_uuid: Uuid,
        service_uuid: Uuid,
        characteristic_uuid: Uuid,
        error_description: String,
    ) {
        if let Some(characteristic) =
            self.get_characteristic(peripheral_uuid, service_uuid, characteristic_uuid)
        {
            trace!("Got subscribe/unsubscribe error: {}", error_description);
            if let Some(state) = characteristic
                .subscribe_future_state
                .pop_back()
                .or_else(|| characteristic.unsubscribe_future_state.pop_back())
            {
                state
                    .lock()
                    .unwrap()
                    .set_reply(CoreBluetoothReply::Err(error_description));
            }
        }
    }

    async fn on_characteristic_read(
        &mut self,
        peripheral_uuid: Uuid,
        service_uuid: Uuid,
        characteristic_uuid: Uuid,
        data: Vec<u8>,
    ) {
        if let Some(peripheral) = self.peripherals.get_mut(&peripheral_uuid) {
            if let Some(service) = peripheral.services.get_mut(&service_uuid) {
                if let Some(characteristic) = service.characteristics.get_mut(&characteristic_uuid)
                {
                    trace!("Got read event!");

                    let mut data_clone = Vec::new();
                    for byte in data.iter() {
                        data_clone.push(*byte);
                    }
                    // Reads and notifications both return the same callback. If
                    // we're trying to do a read, we'll have a future we can
                    // fulfill. Otherwise, just treat the returned value as a
                    // notification and use the event system.
                    if !characteristic.read_future_state.is_empty() {
                        let state = characteristic.read_future_state.pop_back().unwrap();
                        state
                            .lock()
                            .unwrap()
                            .set_reply(CoreBluetoothReply::ReadResult(data_clone));
                    } else if let Err(e) = peripheral
                        .event_sender
                        .send(PeripheralEventInternal::Notification(
                            characteristic_uuid,
                            service_uuid,
                            data,
                        ))
                        .await
                    {
                        error!("Error sending notification event: {}", e);
                    }
                }
            }
        }
    }

    fn on_characteristic_read_failed(
        &mut self,
        peripheral_uuid: Uuid,
        service_uuid: Uuid,
        characteristic_uuid: Uuid,
        error_description: String,
    ) {
        if let Some(characteristic) =
            self.get_characteristic(peripheral_uuid, service_uuid, characteristic_uuid)
        {
            trace!("Got read error: {}", error_description);
            if let Some(state) = characteristic.read_future_state.pop_back() {
                state
                    .lock()
                    .unwrap()
                    .set_reply(CoreBluetoothReply::Err(error_description));
            }
        }
    }

    fn on_characteristic_written(
        &mut self,
        peripheral_uuid: Uuid,
        service_uuid: Uuid,
        characteristic_uuid: Uuid,
    ) {
        if let Some(characteristic) =
            self.get_characteristic(peripheral_uuid, service_uuid, characteristic_uuid)
        {
            trace!("Got written event!");
            if let Some(state) = characteristic.write_future_state.pop_back() {
                state.lock().unwrap().set_reply(CoreBluetoothReply::Ok);
            }
        }
    }

    fn on_characteristic_write_failed(
        &mut self,
        peripheral_uuid: Uuid,
        service_uuid: Uuid,
        characteristic_uuid: Uuid,
        error_description: String,
    ) {
        if let Some(characteristic) =
            self.get_characteristic(peripheral_uuid, service_uuid, characteristic_uuid)
        {
            trace!("Got write error: {}", error_description);
            if let Some(state) = characteristic.write_future_state.pop_back() {
                state
                    .lock()
                    .unwrap()
                    .set_reply(CoreBluetoothReply::Err(error_description));
            }
        }
    }

    fn connect_peripheral(&mut self, peripheral_uuid: Uuid, fut: CoreBluetoothReplyStateShared) {
        trace!("Trying to connect peripheral!");
        if let Some(p) = self.peripherals.get_mut(&peripheral_uuid) {
            trace!("Connecting peripheral!");
            if let Some(prev) = p.connected_future_state.replace(fut) {
                prev.lock()
                    .unwrap()
                    .set_reply(CoreBluetoothReply::Err("Superseded by new connect".into()));
            }
            unsafe { self.manager.connectPeripheral_options(&p.peripheral, None) };
        } else {
            fut.lock()
                .unwrap()
                .set_reply(CoreBluetoothReply::Err("Peripheral not found".into()));
        }
    }

    async fn disconnect_peripheral(
        &mut self,
        peripheral_uuid: Uuid,
        fut: CoreBluetoothReplyStateShared,
    ) {
        trace!("Trying to disconnect peripheral!");
        if let Some(p) = self.peripherals.get_mut(&peripheral_uuid) {
            let cb_state = unsafe { p.peripheral.state() };
            if cb_state == CBPeripheralState::Disconnected {
                trace!("Peripheral already disconnected; cleaning up immediately");
                if let Some(mut removed) = self.peripherals.remove(&peripheral_uuid) {
                    removed.confirm_disconnect();
                }
                fut.lock().unwrap().set_reply(CoreBluetoothReply::Ok);
                self.dispatch_event(CoreBluetoothEvent::DeviceDisconnected {
                    uuid: peripheral_uuid,
                })
                .await;
                return;
            }
            trace!("Disconnecting peripheral!");
            if let Some(prev) = p.disconnected_future_state.replace(fut) {
                prev.lock().unwrap().set_reply(CoreBluetoothReply::Ok);
            }
            unsafe { self.manager.cancelPeripheralConnection(&p.peripheral) };
        } else {
            fut.lock().unwrap().set_reply(CoreBluetoothReply::Ok);
        }
    }

    fn is_connected(&mut self, peripheral_uuid: Uuid, fut: CoreBluetoothReplyStateShared) {
        if let Some(p) = self.peripherals.get_mut(&peripheral_uuid) {
            let state = unsafe { p.peripheral.state() };
            trace!("Connected state {:?} ", state);
            fut.lock()
                .unwrap()
                .set_reply(CoreBluetoothReply::State(state));
        } else {
            // Peripheral was removed after disconnect — report as disconnected
            // rather than hanging the future forever.
            fut.lock()
                .unwrap()
                .set_reply(CoreBluetoothReply::State(CBPeripheralState::Disconnected));
        }
    }

    fn write_value(
        &mut self,
        peripheral_uuid: Uuid,
        service_uuid: Uuid,
        characteristic_uuid: Uuid,
        data: Vec<u8>,
        kind: WriteType,
        fut: CoreBluetoothReplyStateShared,
    ) {
        let Some(peripheral) = self.peripherals.get_mut(&peripheral_uuid) else {
            fut.lock()
                .unwrap()
                .set_reply(CoreBluetoothReply::Err("Peripheral not found".into()));
            return;
        };
        let Some(service) = peripheral.services.get_mut(&service_uuid) else {
            fut.lock()
                .unwrap()
                .set_reply(CoreBluetoothReply::Err("Service not found".into()));
            return;
        };
        let Some(characteristic) = service.characteristics.get_mut(&characteristic_uuid) else {
            fut.lock()
                .unwrap()
                .set_reply(CoreBluetoothReply::Err("Characteristic not found".into()));
            return;
        };
        trace!("Writing value! With kind {:?}", kind);
        match kind {
            WriteType::WithoutResponse => {
                let ns_data = NSData::from_vec(data);
                let queue = peripheral.cb_write_queue.clone();
                queue.enqueue(PendingCbWriteItem {
                    characteristic: characteristic.characteristic.clone(),
                    data: ns_data,
                    fut,
                });
                let ptr = Arc::into_raw(queue) as *mut c_void;
                unsafe {
                    ffi::dispatch_async_f(self.cb_queue, ptr, drain_cb_write_queue_trampoline);
                }
            }
            WriteType::WithResponse => {
                characteristic.write_future_state.push_front(fut);
                unsafe {
                    peripheral.peripheral.writeValue_forCharacteristic_type(
                        &NSData::from_vec(data),
                        &characteristic.characteristic,
                        CBCharacteristicWriteType::CBCharacteristicWriteWithResponse,
                    );
                }
            }
        }
    }

    fn read_value(
        &mut self,
        peripheral_uuid: Uuid,
        service_uuid: Uuid,
        characteristic_uuid: Uuid,
        fut: CoreBluetoothReplyStateShared,
    ) {
        if let Some(peripheral) = self.peripherals.get_mut(&peripheral_uuid) {
            if let Some(service) = peripheral.services.get_mut(&service_uuid) {
                if let Some(characteristic) = service.characteristics.get_mut(&characteristic_uuid)
                {
                    trace!("Reading value!");
                    characteristic.read_future_state.push_front(fut);
                    unsafe {
                        peripheral
                            .peripheral
                            .readValueForCharacteristic(&characteristic.characteristic);
                    }
                    return;
                }
            }
        }
        fut.lock().unwrap().set_reply(CoreBluetoothReply::Err(
            "Characteristic not available".into(),
        ));
    }

    fn subscribe(
        &mut self,
        peripheral_uuid: Uuid,
        service_uuid: Uuid,
        characteristic_uuid: Uuid,
        fut: CoreBluetoothReplyStateShared,
    ) {
        if let Some(peripheral) = self.peripherals.get_mut(&peripheral_uuid) {
            if let Some(service) = peripheral.services.get_mut(&service_uuid) {
                if let Some(characteristic) = service.characteristics.get_mut(&characteristic_uuid)
                {
                    trace!("Setting subscribe!");
                    characteristic.subscribe_future_state.push_front(fut);
                    unsafe {
                        peripheral
                            .peripheral
                            .setNotifyValue_forCharacteristic(true, &characteristic.characteristic);
                    }
                    return;
                }
            }
        }
        fut.lock().unwrap().set_reply(CoreBluetoothReply::Err(
            "Characteristic not available".into(),
        ));
    }

    fn unsubscribe(
        &mut self,
        peripheral_uuid: Uuid,
        service_uuid: Uuid,
        characteristic_uuid: Uuid,
        fut: CoreBluetoothReplyStateShared,
    ) {
        if let Some(peripheral) = self.peripherals.get_mut(&peripheral_uuid) {
            if let Some(service) = peripheral.services.get_mut(&service_uuid) {
                if let Some(characteristic) = service.characteristics.get_mut(&characteristic_uuid)
                {
                    trace!("Setting subscribe!");
                    characteristic.unsubscribe_future_state.push_front(fut);
                    unsafe {
                        peripheral.peripheral.setNotifyValue_forCharacteristic(
                            false,
                            &characteristic.characteristic,
                        );
                    }
                    return;
                }
            }
        }
        fut.lock().unwrap().set_reply(CoreBluetoothReply::Err(
            "Characteristic not available".into(),
        ));
    }

    fn write_descriptor_value(
        &mut self,
        peripheral_uuid: Uuid,
        service_uuid: Uuid,
        characteristic_uuid: Uuid,
        descriptor_uuid: Uuid,
        data: Vec<u8>,
        fut: CoreBluetoothReplyStateShared,
    ) {
        if let Some(peripheral) = self.peripherals.get_mut(&peripheral_uuid) {
            if let Some(service) = peripheral.services.get_mut(&service_uuid) {
                if let Some(characteristic) = service.characteristics.get_mut(&characteristic_uuid)
                {
                    if let Some(descriptor) = characteristic.descriptors.get_mut(&descriptor_uuid) {
                        trace!("Writing descriptor value!");
                        descriptor.write_future_state.push_front(fut);
                        unsafe {
                            peripheral.peripheral.writeValue_forDescriptor(
                                &NSData::from_vec(data),
                                &descriptor.descriptor,
                            );
                        }
                        return;
                    }
                }
            }
        }
        fut.lock().unwrap().set_reply(CoreBluetoothReply::Err(
            "Descriptor not available".into(),
        ));
    }

    fn read_descriptor_value(
        &mut self,
        peripheral_uuid: Uuid,
        service_uuid: Uuid,
        characteristic_uuid: Uuid,
        descriptor_uuid: Uuid,
        fut: CoreBluetoothReplyStateShared,
    ) {
        if let Some(peripheral) = self.peripherals.get_mut(&peripheral_uuid) {
            if let Some(service) = peripheral.services.get_mut(&service_uuid) {
                if let Some(characteristic) = service.characteristics.get_mut(&characteristic_uuid)
                {
                    if let Some(descriptor) = characteristic.descriptors.get_mut(&descriptor_uuid) {
                        trace!("Reading descriptor value!");
                        descriptor.read_future_state.push_front(fut);
                        unsafe {
                            peripheral
                                .peripheral
                                .readValueForDescriptor(&descriptor.descriptor);
                        }
                        return;
                    }
                }
            }
        }
        fut.lock().unwrap().set_reply(CoreBluetoothReply::Err(
            "Descriptor not available".into(),
        ));
    }

    fn read_rssi(&mut self, peripheral_uuid: Uuid, fut: CoreBluetoothReplyStateShared) {
        if let Some(peripheral) = self.peripherals.get_mut(&peripheral_uuid) {
            trace!("Reading RSSI!");
            peripheral.read_rssi_future_state.push_front(fut);
            unsafe {
                peripheral.peripheral.readRSSI();
            }
        } else {
            fut.lock()
                .unwrap()
                .set_reply(CoreBluetoothReply::Err("Peripheral not found".into()));
        }
    }

    async fn on_read_rssi(&mut self, peripheral_uuid: Uuid, rssi: i16) {
        if let Some(peripheral) = self.peripherals.get_mut(&peripheral_uuid) {
            trace!("Got RSSI read event: {}", rssi);
            if let Some(state) = peripheral.read_rssi_future_state.pop_back() {
                state
                    .lock()
                    .unwrap()
                    .set_reply(CoreBluetoothReply::ReadRssi(rssi));
            }
            // Also send as a peripheral event for CentralEvent emission
            if let Err(e) = peripheral
                .event_sender
                .send(PeripheralEventInternal::RssiRead(rssi))
                .await
            {
                error!("Error sending RSSI event: {}", e);
            }
        }
    }

    async fn on_tx_power_level(&mut self, peripheral_uuid: Uuid, tx_power_level: i16) {
        if let Some(peripheral) = self.peripherals.get_mut(&peripheral_uuid) {
            if let Err(e) = peripheral
                .event_sender
                .send(PeripheralEventInternal::TxPowerLevel(tx_power_level))
                .await
            {
                error!("Error sending tx_power_level event: {}", e);
            }
        }
    }

    async fn on_descriptor_read(
        &mut self,
        peripheral_uuid: Uuid,
        service_uuid: Uuid,
        characteristic_uuid: Uuid,
        descriptor_uuid: Uuid,
        data: Vec<u8>,
    ) {
        if let Some(peripheral) = self.peripherals.get_mut(&peripheral_uuid) {
            if let Some(service) = peripheral.services.get_mut(&service_uuid) {
                if let Some(characteristic) = service.characteristics.get_mut(&characteristic_uuid)
                {
                    if let Some(descriptor) = characteristic.descriptors.get_mut(&descriptor_uuid) {
                        trace!("Got read event!");

                        let mut data_clone = Vec::new();
                        for byte in data.iter() {
                            data_clone.push(*byte);
                        }
                        if let Some(state) = descriptor.read_future_state.pop_back() {
                            state
                                .lock()
                                .unwrap()
                                .set_reply(CoreBluetoothReply::ReadResult(data_clone));
                        }
                    }
                }
            }
        }
    }

    fn on_descriptor_read_failed(
        &mut self,
        peripheral_uuid: Uuid,
        service_uuid: Uuid,
        characteristic_uuid: Uuid,
        descriptor_uuid: Uuid,
        error_description: String,
    ) {
        if let Some(descriptor) = self.get_descriptor(
            peripheral_uuid,
            service_uuid,
            characteristic_uuid,
            descriptor_uuid,
        ) {
            trace!("Got descriptor read error: {}", error_description);
            if let Some(state) = descriptor.read_future_state.pop_back() {
                state
                    .lock()
                    .unwrap()
                    .set_reply(CoreBluetoothReply::Err(error_description));
            }
        }
    }

    fn on_descriptor_written(
        &mut self,
        peripheral_uuid: Uuid,
        service_uuid: Uuid,
        characteristic_uuid: Uuid,
        descriptor_uuid: Uuid,
    ) {
        if let Some(descriptor) = self.get_descriptor(
            peripheral_uuid,
            service_uuid,
            characteristic_uuid,
            descriptor_uuid,
        ) {
            trace!("Got written event!");
            if let Some(state) = descriptor.write_future_state.pop_back() {
                state.lock().unwrap().set_reply(CoreBluetoothReply::Ok);
            }
        }
    }

    fn on_descriptor_write_failed(
        &mut self,
        peripheral_uuid: Uuid,
        service_uuid: Uuid,
        characteristic_uuid: Uuid,
        descriptor_uuid: Uuid,
        error_description: String,
    ) {
        if let Some(descriptor) = self.get_descriptor(
            peripheral_uuid,
            service_uuid,
            characteristic_uuid,
            descriptor_uuid,
        ) {
            trace!("Got descriptor write error: {}", error_description);
            if let Some(state) = descriptor.write_future_state.pop_back() {
                state
                    .lock()
                    .unwrap()
                    .set_reply(CoreBluetoothReply::Err(error_description));
            }
        }
    }

    fn discover_services(&mut self, peripheral_uuid: Uuid, fut: CoreBluetoothReplyStateShared) {
        if let Some(p) = self.peripherals.get_mut(&peripheral_uuid) {
            trace!("Discovering services!");
            if let Some(prev) = p.services_discovered_future_state.replace(fut) {
                prev.lock().unwrap().set_reply(CoreBluetoothReply::Err(
                    "Superseded by new discover_services".into(),
                ));
            }
            // This will trigger the delegate_peripheral_diddiscoverservices in central_delegate.rs
            unsafe { p.peripheral.discoverServices(None) };
        } else {
            fut.lock()
                .unwrap()
                .set_reply(CoreBluetoothReply::Err("Peripheral not found".into()));
        }
    }

    async fn wait_for_message(&mut self) {
        let has_pending_cb_writes = self
            .peripherals
            .values()
            .any(|p| p.cb_write_queue.has_pending());
        let mut cb_kick = if has_pending_cb_writes {
            futures::future::Either::Left(Box::pin(tokio::time::sleep(Duration::from_millis(20))).fuse())
        } else {
            futures::future::Either::Right(futures::future::pending::<()>().fuse())
        };
        select! {
            delegate_msg = self.delegate_receiver.select_next_some() => {
                match delegate_msg {
                    // TODO We should probably also register some sort of
                    // "ready" variable in our adapter that will cause scans/etc
                    // to fail if this hasn't updated.
                    CentralDelegateEvent::DidUpdateState{state} => {
                        if state == CBManagerState::PoweredOff {
                            self.on_adapter_powered_off().await;
                        }
                        self.dispatch_event(CoreBluetoothEvent::DidUpdateState{state}).await
                    }
                    CentralDelegateEvent::DiscoveredPeripheral{cbperipheral, advertisement_name} => {
                        self.on_discovered_peripheral(cbperipheral, advertisement_name).await
                    }
                    CentralDelegateEvent::DiscoveredServices{peripheral_uuid, services} => {
                        self.on_discovered_services(peripheral_uuid, services)
                    }
                    CentralDelegateEvent::DiscoveredCharacteristics{peripheral_uuid, service_uuid, characteristics} => {
                        self.on_discovered_characteristics(peripheral_uuid, service_uuid, characteristics)
                    }
                    CentralDelegateEvent::DiscoveredCharacteristicDescriptors{peripheral_uuid, service_uuid, characteristic_uuid, descriptors} => {
                        self.on_discovered_characteristic_descriptors(peripheral_uuid, service_uuid, characteristic_uuid, descriptors)
                    }
                    CentralDelegateEvent::ConnectedDevice{peripheral_uuid} => {
                        self.on_peripheral_connect(peripheral_uuid)
                    },
                    CentralDelegateEvent::ConnectionFailed{peripheral_uuid, error_description} => {
                        self.on_peripheral_connection_failed(peripheral_uuid, error_description).await
                    },
                    CentralDelegateEvent::DisconnectedDevice{peripheral_uuid} => {
                        self.on_peripheral_disconnect(peripheral_uuid).await
                    }
                    CentralDelegateEvent::CharacteristicSubscribed{
                        peripheral_uuid,
                        service_uuid,
                        characteristic_uuid,
                     } => self.on_characteristic_subscribed(peripheral_uuid, service_uuid, characteristic_uuid),
                    CentralDelegateEvent::CharacteristicSubscribeFailed{
                        peripheral_uuid,
                        service_uuid,
                        characteristic_uuid,
                        error_description,
                     } => self.on_characteristic_subscribe_failed(peripheral_uuid, service_uuid, characteristic_uuid, error_description),
                    CentralDelegateEvent::CharacteristicUnsubscribed{
                        peripheral_uuid,
                        service_uuid,
                        characteristic_uuid,
                     } => self.on_characteristic_unsubscribed(peripheral_uuid, service_uuid,characteristic_uuid),
                    CentralDelegateEvent::CharacteristicNotified{
                        peripheral_uuid,
                        service_uuid,
                        characteristic_uuid,
                        data,
                     } => self.on_characteristic_read(peripheral_uuid, service_uuid,characteristic_uuid, data).await,
                    CentralDelegateEvent::CharacteristicReadFailed{
                        peripheral_uuid,
                        service_uuid,
                        characteristic_uuid,
                        error_description,
                     } => self.on_characteristic_read_failed(peripheral_uuid, service_uuid, characteristic_uuid, error_description),
                    CentralDelegateEvent::CharacteristicWritten{
                        peripheral_uuid,
                        service_uuid,
                        characteristic_uuid,
                    } => self.on_characteristic_written(peripheral_uuid, service_uuid, characteristic_uuid),
                    CentralDelegateEvent::CharacteristicWriteFailed{
                        peripheral_uuid,
                        service_uuid,
                        characteristic_uuid,
                        error_description,
                    } => self.on_characteristic_write_failed(peripheral_uuid, service_uuid, characteristic_uuid, error_description),
                    CentralDelegateEvent::ManufacturerData{peripheral_uuid, manufacturer_id, data, rssi} => {
                        self.on_manufacturer_data(peripheral_uuid, manufacturer_id, data, rssi).await
                    },
                    CentralDelegateEvent::ServiceData{peripheral_uuid, service_data, rssi} => {
                        self.on_service_data(peripheral_uuid, service_data, rssi).await
                    },
                    CentralDelegateEvent::Services{peripheral_uuid, service_uuids, rssi} => {
                        self.on_services(peripheral_uuid, service_uuids, rssi).await
                    },
                    CentralDelegateEvent::ServicesModified{peripheral_uuid} => {
                        self.on_services_modified(peripheral_uuid).await
                    },
                    CentralDelegateEvent::DescriptorNotified{
                        peripheral_uuid,
                        service_uuid,
                        characteristic_uuid,
                        descriptor_uuid,
                        data,
                     } => self.on_descriptor_read(peripheral_uuid, service_uuid, characteristic_uuid, descriptor_uuid, data).await,
                    CentralDelegateEvent::DescriptorReadFailed{
                        peripheral_uuid,
                        service_uuid,
                        characteristic_uuid,
                        descriptor_uuid,
                        error_description,
                     } => self.on_descriptor_read_failed(peripheral_uuid, service_uuid, characteristic_uuid, descriptor_uuid, error_description),
                    CentralDelegateEvent::DescriptorWritten{
                        peripheral_uuid,
                        service_uuid,
                        characteristic_uuid,
                        descriptor_uuid,
                    } => self.on_descriptor_written(peripheral_uuid, service_uuid, characteristic_uuid, descriptor_uuid),
                    CentralDelegateEvent::DescriptorWriteFailed{
                        peripheral_uuid,
                        service_uuid,
                        characteristic_uuid,
                        descriptor_uuid,
                        error_description,
                    } => self.on_descriptor_write_failed(peripheral_uuid, service_uuid, characteristic_uuid, descriptor_uuid, error_description),
                    CentralDelegateEvent::TxPowerLevel{peripheral_uuid, tx_power_level} => {
                        self.on_tx_power_level(peripheral_uuid, tx_power_level).await
                    },
                    CentralDelegateEvent::DidReadRssi{peripheral_uuid, rssi} => {
                        self.on_read_rssi(peripheral_uuid, rssi).await
                    },
                    CentralDelegateEvent::ReadyToSendWriteWithoutResponse{peripheral_uuid} => {
                        self.schedule_cb_write_drain(peripheral_uuid)
                    },
                };
            }
            adapter_msg = self.message_receiver.select_next_some() => {
                trace!("Adapter message!");
                match adapter_msg {
                    CoreBluetoothMessage::GetAdapterState { future } => {
                        self.get_adapter_state(future);
                    },
                    CoreBluetoothMessage::StartScanning{filter} => self.start_discovery(filter),
                    CoreBluetoothMessage::StopScanning => self.stop_discovery(),
                    CoreBluetoothMessage::ConnectDevice{peripheral_uuid, future} => {
                        trace!("got connectdevice msg!");
                        self.connect_peripheral(peripheral_uuid, future);
                    }
                    CoreBluetoothMessage::DisconnectDevice{peripheral_uuid, future} => {
                        self.disconnect_peripheral(peripheral_uuid, future).await;
                    }
                    CoreBluetoothMessage::ReadValue{peripheral_uuid, service_uuid,characteristic_uuid, future} => {
                        self.read_value(peripheral_uuid, service_uuid,characteristic_uuid, future)
                    }
                    CoreBluetoothMessage::WriteValue{
                        peripheral_uuid,service_uuid,
                        characteristic_uuid,
                        data,
                        write_type,
                        future,
                    } => self.write_value(peripheral_uuid, service_uuid,characteristic_uuid, data, write_type, future),
                    CoreBluetoothMessage::Subscribe{peripheral_uuid, service_uuid,characteristic_uuid, future} => {
                        self.subscribe(peripheral_uuid, service_uuid,characteristic_uuid, future)
                    }
                    CoreBluetoothMessage::Unsubscribe{peripheral_uuid, service_uuid,characteristic_uuid, future} => {
                        self.unsubscribe(peripheral_uuid, service_uuid,characteristic_uuid, future)
                    }
                    CoreBluetoothMessage::IsConnected{peripheral_uuid, future} => {
                        self.is_connected(peripheral_uuid, future);
                    },
                    CoreBluetoothMessage::ReadDescriptorValue{peripheral_uuid, service_uuid, characteristic_uuid, descriptor_uuid, future} => {
                        self.read_descriptor_value(peripheral_uuid, service_uuid, characteristic_uuid, descriptor_uuid, future)
                    }
                    CoreBluetoothMessage::WriteDescriptorValue{
                        peripheral_uuid,service_uuid,
                        characteristic_uuid,
                        descriptor_uuid,
                        data,
                        future,
                    } => self.write_descriptor_value(peripheral_uuid, service_uuid, characteristic_uuid, descriptor_uuid, data, future),
                    CoreBluetoothMessage::DiscoverServices{peripheral_uuid, future} => {
                        self.discover_services(peripheral_uuid, future);
                    }
                    CoreBluetoothMessage::ReadRssi{peripheral_uuid, future} => {
                        self.read_rssi(peripheral_uuid, future)
                    }
                };
            }
            _ = cb_kick => {
                self.schedule_all_pending_cb_write_drains();
            }
        }
    }

    fn get_adapter_state(&mut self, fut: CoreBluetoothReplyStateShared) {
        let state = unsafe { self.manager.state() };
        fut.lock()
            .unwrap()
            .set_reply(CoreBluetoothReply::AdapterState(state))
    }

    fn start_discovery(&mut self, filter: ScanFilter) {
        trace!("BluetoothAdapter::start_discovery");
        let service_uuids = scan_filter_to_service_uuids(filter);
        let mut options = NSMutableDictionary::new();
        // NOTE: If duplicates are not allowed then a peripheral will not show
        // up again once connected and then disconnected.
        options.insert_id(
            unsafe { CBCentralManagerScanOptionAllowDuplicatesKey },
            Retained::into_super(Retained::into_super(Retained::into_super(
                NSNumber::new_bool(true),
            ))),
        );
        unsafe {
            self.manager
                .scanForPeripheralsWithServices_options(service_uuids.as_deref(), Some(&options))
        };
    }

    fn stop_discovery(&mut self) {
        trace!("BluetoothAdapter::stop_discovery");
        unsafe { self.manager.stopScan() };
    }
}

/// Convert a `ScanFilter` to the appropriate `NSArray<CBUUID *> *` to use for discovery. If the
/// filter has an empty list of services then this will return `nil`, to discover all devices.
fn scan_filter_to_service_uuids(filter: ScanFilter) -> Option<Retained<NSArray<CBUUID>>> {
    if filter.services.is_empty() {
        None
    } else {
        let service_uuids = filter
            .services
            .into_iter()
            .map(uuid_to_cbuuid)
            .collect::<Vec<_>>();
        Some(NSArray::from_vec(service_uuids))
    }
}

impl Drop for CoreBluetoothInternal {
    fn drop(&mut self) {
        trace!("BluetoothAdapter::drop");
        // NOTE: stop discovery only here instead of in BluetoothDiscoverySession
        self.stop_discovery();
        if !self.cb_queue.is_null() {
            unsafe { ffi::dispatch_release(self.cb_queue) };
            self.cb_queue = std::ptr::null_mut();
        }
    }
}

pub fn run_corebluetooth_thread(
    event_sender: Sender<CoreBluetoothEvent>,
) -> Result<Sender<CoreBluetoothMessage>, Error> {
    let authorization = unsafe { CBManager::authorization_class() };
    if authorization != CBManagerAuthorization::AllowedAlways
        && authorization != CBManagerAuthorization::NotDetermined
    {
        warn!("Authorization status {:?}", authorization);
        return Err(Error::PermissionDenied);
    } else {
        trace!("Authorization status {:?}", authorization);
    }
    let (sender, receiver) = mpsc::channel::<CoreBluetoothMessage>(256);
    // CoreBluetoothInternal is !Send, so we need to keep it on a single thread.
    thread::spawn(move || {
        let runtime = runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .unwrap();
        runtime.block_on(async move {
            let mut cbi = CoreBluetoothInternal::new(receiver, event_sender);
            loop {
                cbi.wait_for_message().await;
            }
        })
    });
    Ok(sender)
}
