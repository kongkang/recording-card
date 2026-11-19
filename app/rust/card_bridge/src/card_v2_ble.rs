//! CardV2 (`DYJV2_*` 与 `DFU_DYJ`) 统一 BLE 连接与抗卡死 Secure DFU 断点续传引擎。
//!
//! 关键职责：
//! 1. 复用全局唯一 `Adapter`（消除双 `CBCentralManager` 实例竞态与外设缓存隔离）。
//! 2. 为普通 NUS 通信与 DFU 写通道统一加上界超时（`TimedCardV2BleTransport` / `TimedDfuTransport`）。
//! 3. DFU 传输层若遭遇写超时或蓝牙闪断，立刻主动断链并在 4KB 对象边界自动重连 `DFU_DYJ`
//!    触发 Bootloader 断点续传，同时对不可恢复的协议/签名错误立即中止。

use std::collections::HashSet;
use std::future::Future;
use std::sync::Arc;
use std::time::Duration;

use async_trait::async_trait;
use btleplug::api::{
    Central as _, CentralEvent, CharPropFlags, Characteristic, Peripheral as _, ScanFilter,
    WriteType,
};
use btleplug::platform::{Adapter, Peripheral};
use futures::StreamExt;
use reai_card_sdk::{
    BleTransport, DFU_ADVERTISED_NAME, DFU_CONTROL_POINT_UUID, DFU_PACKET_UUID, DFU_SERVICE_UUID,
    DfuOptions, DfuPackage, DfuProgress, DfuReport, DfuStage, DfuTarget, DfuTransport,
    DyjDevice as CardV2Device, NUS_NOTIFY_UUID, NUS_WRITE_UUID, NotificationStream,
    Result as SdkResult, SdkError as CardSdkError, SharedDfuTransport, SharedTransport,
};
use uuid::Uuid;

use crate::BridgeError;
use crate::capabilities::is_card_v2_dfu_advertisement;

const NUS_WRITE_TIMEOUT: Duration = Duration::from_secs(6);
const NOTIFICATIONS_TIMEOUT: Duration = Duration::from_secs(5);
const BLE_CONNECT_TIMEOUT: Duration = Duration::from_secs(12);
const BLE_DISCOVER_TIMEOUT: Duration = Duration::from_secs(8);
const BLE_SUBSCRIBE_TIMEOUT: Duration = Duration::from_secs(6);
const BLE_DISCONNECT_TIMEOUT: Duration = Duration::from_secs(3);
const HANDSHAKE_TIMEOUT: Duration = Duration::from_secs(10);

const DFU_CONTROL_WRITE_TIMEOUT: Duration = Duration::from_secs(6);
const DFU_PACKET_WRITE_TIMEOUT: Duration = Duration::from_millis(2500);
const DFU_SCAN_WINDOW: Duration = Duration::from_secs(2);
const DFU_RECONNECT_PAUSE: Duration = Duration::from_millis(800);

const MAX_STALL_ATTEMPTS: u32 = 4;
const MAX_TOTAL_ATTEMPTS: u32 = 12;
const MIN_PAGE_ADVANCE_BYTES: usize = 4096;

pub enum CardV2ConnectOutcome {
    Connected {
        device: CardV2Device,
        id: String,
        name: String,
    },
    DfuRecovery {
        id: String,
        name: String,
    },
}

struct TimedCardV2BleTransport {
    peripheral: Peripheral,
    write: Characteristic,
    write_type: WriteType,
}

#[async_trait]
impl BleTransport for TimedCardV2BleTransport {
    async fn write(&self, bytes: &[u8]) -> SdkResult<()> {
        tokio::time::timeout(
            NUS_WRITE_TIMEOUT,
            self.peripheral
                .write(&self.write, bytes, self.write_type),
        )
        .await
        .map_err(|_| CardSdkError::Timeout {
            command: "BLE write".into(),
            seconds: NUS_WRITE_TIMEOUT.as_secs(),
        })?
        .map_err(|e| CardSdkError::Transport(e.to_string()))
    }

    async fn notifications(&self) -> SdkResult<NotificationStream> {
        let stream = tokio::time::timeout(NOTIFICATIONS_TIMEOUT, self.peripheral.notifications())
            .await
            .map_err(|_| CardSdkError::Timeout {
                command: "BLE notifications".into(),
                seconds: NOTIFICATIONS_TIMEOUT.as_secs(),
            })?
            .map_err(|e| CardSdkError::Transport(e.to_string()))?;
        Ok(Box::pin(stream.map(|n| Ok(n.value))))
    }

    async fn disconnect(&self) -> SdkResult<()> {
        disconnect_bounded(&self.peripheral).await;
        Ok(())
    }
}

struct TimedDfuTransport {
    peripheral: Peripheral,
    control: Characteristic,
    packet: Characteristic,
}

#[async_trait]
impl DfuTransport for TimedDfuTransport {
    async fn write_control(&self, bytes: &[u8]) -> SdkResult<()> {
        tokio::time::timeout(
            DFU_CONTROL_WRITE_TIMEOUT,
            self.peripheral
                .write(&self.control, bytes, WriteType::WithResponse),
        )
        .await
        .map_err(|_| CardSdkError::Timeout {
            command: "DFU control write".into(),
            seconds: DFU_CONTROL_WRITE_TIMEOUT.as_secs(),
        })?
        .map_err(|e| CardSdkError::Transport(e.to_string()))
    }

    async fn write_packet(&self, bytes: &[u8]) -> SdkResult<()> {
        tokio::time::timeout(
            DFU_PACKET_WRITE_TIMEOUT,
            self.peripheral
                .write(&self.packet, bytes, WriteType::WithoutResponse),
        )
        .await
        .map_err(|_| CardSdkError::Timeout {
            command: "DFU packet write".into(),
            seconds: DFU_PACKET_WRITE_TIMEOUT.as_secs().max(2),
        })?
        .map_err(|e| CardSdkError::Transport(e.to_string()))
    }

    async fn notifications(&self) -> SdkResult<NotificationStream> {
        let control_uuid = self.control.uuid;
        let stream = tokio::time::timeout(NOTIFICATIONS_TIMEOUT, self.peripheral.notifications())
            .await
            .map_err(|_| CardSdkError::Timeout {
                command: "DFU notifications".into(),
                seconds: NOTIFICATIONS_TIMEOUT.as_secs(),
            })?
            .map_err(|e| CardSdkError::Transport(e.to_string()))?;
        Ok(Box::pin(
            stream
                .filter(move |notification| {
                    futures::future::ready(notification.uuid == control_uuid)
                })
                .map(|notification| Ok(notification.value)),
        ))
    }

    async fn disconnect(&self) -> SdkResult<()> {
        disconnect_bounded(&self.peripheral).await;
        Ok(())
    }
}

async fn disconnect_bounded(peripheral: &Peripheral) {
    let is_conn = matches!(
        tokio::time::timeout(Duration::from_secs(2), peripheral.is_connected()).await,
        Ok(Ok(true))
    );
    if is_conn {
        let _ = tokio::time::timeout(BLE_DISCONNECT_TIMEOUT, peripheral.disconnect()).await;
    }
}

fn parse_uuid(value: &str) -> SdkResult<Uuid> {
    Uuid::parse_str(value)
        .map_err(|e| CardSdkError::Transport(format!("invalid SDK UUID `{value}`: {e}")))
}

async fn read_props_bounded(peripheral: &Peripheral) -> Option<btleplug::api::PeripheralProperties> {
    crate::read_peripheral_props_bounded(peripheral).await
}

struct ConnectingSlotGuard<'a>(Option<&'a std::sync::Mutex<Option<Peripheral>>>);

impl<'a> ConnectingSlotGuard<'a> {
    fn set(slot: Option<&'a std::sync::Mutex<Option<Peripheral>>>, p: &Peripheral) -> Self {
        if let Some(m) = slot {
            *m.lock().unwrap() = Some(p.clone());
        }
        Self(slot)
    }

    fn clear(&self) {
        if let Some(m) = self.0 {
            *m.lock().unwrap() = None;
        }
    }
}

impl Drop for ConnectingSlotGuard<'_> {
    fn drop(&mut self) {
        self.clear();
    }
}

async fn connect_peripheral_with_slot(
    peripheral: &Peripheral,
    timeout: Duration,
    connecting_slot: Option<&std::sync::Mutex<Option<Peripheral>>>,
) -> Result<(), BridgeError> {
    let guard = ConnectingSlotGuard::set(connecting_slot, peripheral);
    let res = tokio::time::timeout(timeout, peripheral.connect()).await;
    guard.clear();
    match res {
        Ok(Ok(())) => Ok(()),
        Ok(Err(e)) => {
            disconnect_bounded(peripheral).await;
            Err(BridgeError::from(CardSdkError::Transport(e.to_string())))
        }
        Err(_) => {
            disconnect_bounded(peripheral).await;
            Err(BridgeError::from(CardSdkError::Timeout {
                command: "BLE connect".into(),
                seconds: timeout.as_secs(),
            }))
        }
    }
}

async fn find_card_v2_in_adapter(
    adapter: &Adapter,
    id: &str,
    name_hint: Option<&str>,
    seen_this_scan: Option<&HashSet<String>>,
) -> Option<(Peripheral, String, bool)> {
    let peripherals = adapter.peripherals().await.ok()?;
    let trimmed_hint = name_hint.map(str::trim).filter(|s| !s.is_empty());
    let mut best: Option<(i16, Peripheral, String, bool)> = None;

    for p in peripherals {
        let pid = p.id().to_string();
        if let Some(seen) = seen_this_scan {
            if !seen.contains(&pid) && pid != id {
                continue;
            }
        }
        let Some(props) = read_props_bounded(&p).await else {
            continue;
        };
        let local_name = props
            .local_name
            .as_deref()
            .map(str::trim)
            .filter(|s| !s.is_empty());
        let is_dfu = is_card_v2_dfu_advertisement(local_name, &props.services);
        let Some(matched_name) =
            crate::matches_card_v2_candidate(&pid, id, trimmed_hint, local_name, &props.services)
        else {
            continue;
        };
        let rssi = props.rssi.filter(|r| *r < 0).unwrap_or(-80);
        let resolved_name = if matched_name == pid && is_dfu {
            DFU_ADVERTISED_NAME.to_owned()
        } else if matched_name == pid {
            "DYJV2".to_owned()
        } else {
            matched_name
        };
        match &best {
            Some((best_rssi, _, _, _)) if *best_rssi >= rssi => {}
            _ => best = Some((rssi, p, resolved_name, is_dfu)),
        }
    }

    best.map(|(_, p, name, is_dfu)| (p, name, is_dfu))
}

async fn scan_window_collecting_ids(
    adapter: &Adapter,
    duration: Duration,
) -> SdkResult<HashSet<String>> {
    let mut scan_events = adapter
        .events()
        .await
        .map_err(|e| CardSdkError::Transport(e.to_string()))?;
    let mut seen = HashSet::new();
    adapter
        .start_scan(ScanFilter::default())
        .await
        .map_err(|e| CardSdkError::Transport(e.to_string()))?;
    let pump = async {
        while let Some(ev) = scan_events.next().await {
            let id = match ev {
                CentralEvent::DeviceDiscovered(id)
                | CentralEvent::DeviceUpdated(id)
                | CentralEvent::ManufacturerDataAdvertisement { id, .. }
                | CentralEvent::ServiceDataAdvertisement { id, .. }
                | CentralEvent::ServicesAdvertisement { id, .. } => id,
                _ => continue,
            };
            seen.insert(id.to_string());
        }
    };
    let _ = tokio::time::timeout(duration, pump).await;
    let _ = adapter.stop_scan().await;
    Ok(seen)
}

async fn scan_card_v2_peripheral_live(
    adapter: &Adapter,
    id: &str,
    name_hint: Option<&str>,
) -> Result<(Peripheral, String, bool), BridgeError> {
    for window in [Duration::from_secs(3), Duration::from_secs(5)] {
        let seen = scan_window_collecting_ids(adapter, window)
            .await
            .map_err(BridgeError::from)?;
        if let Some(hit) = find_card_v2_in_adapter(adapter, id, name_hint, Some(&seen)).await {
            return Ok(hit);
        }
    }
    Err(BridgeError::from(CardSdkError::DeviceNotFound(
        name_hint.unwrap_or(id).to_string(),
    )))
}

fn find_nus_characteristics(
    characteristics: &std::collections::BTreeSet<Characteristic>,
) -> SdkResult<(Characteristic, Characteristic)> {
    let write_uuid = parse_uuid(NUS_WRITE_UUID)?;
    let notify_uuid = parse_uuid(NUS_NOTIFY_UUID)?;
    let write = characteristics
        .iter()
        .find(|c| {
            c.uuid == write_uuid
                && (c.properties.contains(CharPropFlags::WRITE)
                    || c.properties.contains(CharPropFlags::WRITE_WITHOUT_RESPONSE))
        })
        .cloned()
        .ok_or(CardSdkError::MissingCharacteristic("write"))?;
    let notify = characteristics
        .iter()
        .find(|c| c.uuid == notify_uuid && c.properties.contains(CharPropFlags::NOTIFY))
        .cloned()
        .ok_or(CardSdkError::MissingCharacteristic("notify"))?;
    Ok((write, notify))
}

fn find_dfu_characteristics(
    characteristics: &std::collections::BTreeSet<Characteristic>,
) -> SdkResult<(Characteristic, Characteristic)> {
    let control_uuid = parse_uuid(DFU_CONTROL_POINT_UUID)?;
    let packet_uuid = parse_uuid(DFU_PACKET_UUID)?;
    let control = characteristics
        .iter()
        .find(|c| c.uuid == control_uuid && c.properties.contains(CharPropFlags::NOTIFY))
        .cloned()
        .ok_or(CardSdkError::MissingCharacteristic("DFU control point"))?;
    let packet = characteristics
        .iter()
        .find(|c| {
            c.uuid == packet_uuid && c.properties.contains(CharPropFlags::WRITE_WITHOUT_RESPONSE)
        })
        .cloned()
        .ok_or(CardSdkError::MissingCharacteristic("DFU packet"))?;
    Ok((control, packet))
}

fn has_dfu_characteristics(characteristics: &std::collections::BTreeSet<Characteristic>) -> bool {
    find_dfu_characteristics(characteristics).is_ok()
}

pub(crate) async fn connect_card_v2_on_adapter(
    adapter: &Adapter,
    id: &str,
    name_hint: Option<&str>,
    connecting_slot: Option<&std::sync::Mutex<Option<Peripheral>>>,
) -> Result<CardV2ConnectOutcome, BridgeError> {
    let hint_is_dfu = name_hint
        .map(str::trim)
        .is_some_and(|nh| nh.to_ascii_uppercase().starts_with("DFU"));

    // 先对缓存 id 尝试 4s 短超时直连；若设备已轮换 RPA 或处于 DFU 恢复广播，立即断开并落回实时扫描新外设。
    let mut preconnected = false;
    let (peripheral, resolved_name) = if !hint_is_dfu {
        if let Some((cached, cached_name, cached_is_dfu)) =
            find_card_v2_in_adapter(adapter, id, name_hint, None).await
        {
            if cached_is_dfu || cached_name.to_ascii_uppercase().starts_with("DFU_DYJ") {
                disconnect_bounded(&cached).await;
                return Ok(CardV2ConnectOutcome::DfuRecovery {
                    id: cached.id().to_string(),
                    name: DFU_ADVERTISED_NAME.to_owned(),
                });
            }
            if connect_peripheral_with_slot(&cached, Duration::from_secs(4), connecting_slot)
                .await
                .is_ok()
            {
                preconnected = true;
                (cached, cached_name)
            } else {
                let (live_p, live_name, live_dfu) =
                    scan_card_v2_peripheral_live(adapter, id, name_hint).await?;
                if live_dfu || live_name.to_ascii_uppercase().starts_with("DFU_DYJ") {
                    disconnect_bounded(&live_p).await;
                    return Ok(CardV2ConnectOutcome::DfuRecovery {
                        id: live_p.id().to_string(),
                        name: DFU_ADVERTISED_NAME.to_owned(),
                    });
                }
                (live_p, live_name)
            }
        } else {
            let (live_p, live_name, live_dfu) =
                scan_card_v2_peripheral_live(adapter, id, name_hint).await?;
            if live_dfu || live_name.to_ascii_uppercase().starts_with("DFU_DYJ") {
                disconnect_bounded(&live_p).await;
                return Ok(CardV2ConnectOutcome::DfuRecovery {
                    id: live_p.id().to_string(),
                    name: DFU_ADVERTISED_NAME.to_owned(),
                });
            }
            (live_p, live_name)
        }
    } else {
        let (live_p, live_name, live_dfu) =
            scan_card_v2_peripheral_live(adapter, id, name_hint).await?;
        if live_dfu || live_name.to_ascii_uppercase().starts_with("DFU_DYJ") {
            disconnect_bounded(&live_p).await;
            return Ok(CardV2ConnectOutcome::DfuRecovery {
                id: live_p.id().to_string(),
                name: DFU_ADVERTISED_NAME.to_owned(),
            });
        }
        (live_p, live_name)
    };
    let actual_id = peripheral.id().to_string();

    let mut attempt = 0u8;
    let (write, notify) = loop {
        if !preconnected {
            connect_peripheral_with_slot(&peripheral, BLE_CONNECT_TIMEOUT, connecting_slot).await?;
        }
        preconnected = false;

        let disc = tokio::time::timeout(BLE_DISCOVER_TIMEOUT, peripheral.discover_services()).await;
        if !matches!(disc, Ok(Ok(()))) {
            disconnect_bounded(&peripheral).await;
            return Err(BridgeError::from(CardSdkError::Transport(
                "discover_services failed or timed out".into(),
            )));
        }

        let chars = peripheral.characteristics();
        match find_nus_characteristics(&chars) {
            Ok(pair) => break pair,
            Err(err) => {
                if attempt == 0 {
                    attempt = 1;
                    disconnect_bounded(&peripheral).await;
                    tokio::time::sleep(Duration::from_secs(1)).await;
                    continue;
                }
                if has_dfu_characteristics(&chars) {
                    disconnect_bounded(&peripheral).await;
                    return Ok(CardV2ConnectOutcome::DfuRecovery {
                        id: actual_id,
                        name: DFU_ADVERTISED_NAME.to_owned(),
                    });
                }
                disconnect_bounded(&peripheral).await;
                return Err(BridgeError::from(err));
            }
        }
    };

    match tokio::time::timeout(BLE_SUBSCRIBE_TIMEOUT, peripheral.subscribe(&notify)).await {
        Ok(Ok(())) => {}
        Ok(Err(e)) => {
            disconnect_bounded(&peripheral).await;
            return Err(BridgeError::from(CardSdkError::Transport(e.to_string())));
        }
        Err(_) => {
            disconnect_bounded(&peripheral).await;
            return Err(BridgeError::from(CardSdkError::Timeout {
                command: "BLE subscribe".into(),
                seconds: BLE_SUBSCRIBE_TIMEOUT.as_secs(),
            }));
        }
    }

    let write_type = if write.properties.contains(CharPropFlags::WRITE) {
        WriteType::WithResponse
    } else {
        WriteType::WithoutResponse
    };
    let transport: SharedTransport = Arc::new(TimedCardV2BleTransport {
        peripheral,
        write,
        write_type,
    });
    match tokio::time::timeout(HANDSHAKE_TIMEOUT, CardV2Device::from_transport(transport.clone()))
        .await
    {
        Ok(Ok(device)) => Ok(CardV2ConnectOutcome::Connected {
            device,
            id: actual_id,
            name: resolved_name,
        }),
        Ok(Err(err)) => {
            let _ = transport.disconnect().await;
            Err(BridgeError::from(err))
        }
        Err(_) => {
            let _ = transport.disconnect().await;
            Err(BridgeError::from(CardSdkError::Timeout {
                command: "SYNC_TIME".into(),
                seconds: HANDSHAKE_TIMEOUT.as_secs(),
            }))
        }
    }
}

pub async fn scan_dfu_peripheral(
    adapter: &Adapter,
    window: Duration,
) -> SdkResult<Option<Peripheral>> {
    let seen = scan_window_collecting_ids(adapter, window).await?;
    let dfu_uuid = parse_uuid(DFU_SERVICE_UUID)?;
    let mut best: Option<(i16, Peripheral)> = None;

    for p in adapter
        .peripherals()
        .await
        .map_err(|e| CardSdkError::Transport(e.to_string()))?
    {
        let pid = p.id().to_string();
        if !seen.contains(&pid) {
            continue;
        }
        let Some(props) = read_props_bounded(&p).await else {
            continue;
        };
        let local_name = props.local_name.as_deref();
        let has_dfu_uuid = props.services.contains(&dfu_uuid);
        if !has_dfu_uuid && !is_card_v2_dfu_advertisement(local_name, &props.services) {
            continue;
        }
        let rssi = props.rssi.filter(|r| *r < 0).unwrap_or(-80);
        match &best {
            Some((best_rssi, _)) if *best_rssi >= rssi => {}
            _ => best = Some((rssi, p)),
        }
    }

    Ok(best.map(|(_, p)| p))
}

pub async fn connect_dfu_target_on_adapter(
    adapter: &Adapter,
    window_budget: Duration,
) -> SdkResult<DfuTarget> {
    let deadline = tokio::time::Instant::now() + window_budget;
    let peripheral = loop {
        if let Some(found) = scan_dfu_peripheral(adapter, DFU_SCAN_WINDOW).await? {
            break found;
        }
        if tokio::time::Instant::now() >= deadline {
            return Err(CardSdkError::DeviceNotFound(format!(
                "{DFU_ADVERTISED_NAME} (bootloader did not advertise within {}s)",
                window_budget.as_secs()
            )));
        }
    };

    let mut attempt = 0u8;
    let (control, packet) = loop {
        tokio::time::timeout(BLE_CONNECT_TIMEOUT, peripheral.connect())
            .await
            .map_err(|_| CardSdkError::Timeout {
                command: "DFU connect".into(),
                seconds: BLE_CONNECT_TIMEOUT.as_secs(),
            })?
            .map_err(|e| CardSdkError::Transport(e.to_string()))?;

        let disc = tokio::time::timeout(BLE_DISCOVER_TIMEOUT, peripheral.discover_services()).await;
        if !matches!(disc, Ok(Ok(()))) {
            disconnect_bounded(&peripheral).await;
            return Err(CardSdkError::Transport(
                "DFU discover_services failed or timed out".into(),
            ));
        }

        match find_dfu_characteristics(&peripheral.characteristics()) {
            Ok(pair) => break pair,
            Err(_err) if attempt == 0 => {
                attempt = 1;
                disconnect_bounded(&peripheral).await;
                tokio::time::sleep(Duration::from_secs(1)).await;
            }
            Err(err) => {
                disconnect_bounded(&peripheral).await;
                return Err(err);
            }
        }
    };

    match tokio::time::timeout(BLE_SUBSCRIBE_TIMEOUT, peripheral.subscribe(&control)).await {
        Ok(Ok(())) => {}
        Ok(Err(e)) => {
            disconnect_bounded(&peripheral).await;
            return Err(CardSdkError::Transport(e.to_string()));
        }
        Err(_) => {
            disconnect_bounded(&peripheral).await;
            return Err(CardSdkError::Timeout {
                command: "DFU subscribe".into(),
                seconds: BLE_SUBSCRIBE_TIMEOUT.as_secs(),
            });
        }
    }

    tokio::time::sleep(Duration::from_millis(250)).await;
    let transport: SharedDfuTransport = Arc::new(TimedDfuTransport {
        peripheral,
        control,
        packet,
    });
    DfuTarget::new(transport).await
}

pub fn is_non_recoverable_dfu_error(err: &CardSdkError) -> bool {
    matches!(err, CardSdkError::DfuPackage(_))
        || matches!(
            err,
            CardSdkError::Dfu {
                result: 0x0B | 0x02 | 0x03 | 0x04 | 0x07,
                ..
            }
        )
}

fn dfu_percent_from_sent(sent: usize, total: usize) -> u8 {
    let denom = total.max(1);
    5u8.saturating_add(((sent.saturating_mul(90)) / denom).min(90) as u8)
}

/// 在单次连接受阻时主动断链、重连 `DFU_DYJ` 并从 Bootloader 4KB 对象偏移自动续传。
pub async fn run_dfu_upload_with_resume<FConnect, Fut>(
    package: &DfuPackage,
    options: &DfuOptions,
    mut connect_next: FConnect,
    mut on_progress: impl FnMut(u8, &str, usize, usize) + Send,
) -> SdkResult<DfuReport>
where
    FConnect: FnMut(u32) -> Fut + Send,
    Fut: Future<Output = SdkResult<DfuTarget>> + Send,
{
    let total_firmware = package.firmware.len();
    let mut max_firmware_sent: usize = 0;
    let mut stall_attempts: u32 = 0;
    let mut total_attempts: u32 = 0;

    loop {
        total_attempts += 1;
        let dfu = match connect_next(total_attempts).await {
            Ok(target) => target,
            Err(err) => {
                if is_non_recoverable_dfu_error(&err) {
                    return Err(err);
                }
                stall_attempts += 1;
                if stall_attempts >= MAX_STALL_ATTEMPTS || total_attempts >= MAX_TOTAL_ATTEMPTS {
                    return Err(err);
                }
                let pct = dfu_percent_from_sent(max_firmware_sent, total_firmware);
                on_progress(
                    pct,
                    "连接 Bootloader 受阻，正在自动重连…",
                    max_firmware_sent,
                    total_firmware,
                );
                tokio::time::sleep(DFU_RECONNECT_PAUSE).await;
                continue;
            }
        };

        let attempt_baseline = max_firmware_sent;
        let upload_res = dfu
            .upload(package, options, |p: DfuProgress| match p.stage {
                DfuStage::InitPacket => {
                    if max_firmware_sent == 0 {
                        on_progress(5, "正在校验固件签名…", 0, total_firmware);
                    }
                }
                DfuStage::Firmware => {
                    if p.sent > max_firmware_sent {
                        max_firmware_sent = p.sent;
                    }
                    let pct = dfu_percent_from_sent(max_firmware_sent, total_firmware);
                    on_progress(pct, "正在写入主控固件…", max_firmware_sent, total_firmware);
                }
            })
            .await;

        let _ = tokio::time::timeout(BLE_DISCONNECT_TIMEOUT, dfu.disconnect()).await;

        match upload_res {
            Ok(report) => {
                on_progress(
                    95,
                    "主控固件写入完成，设备正在重启…",
                    total_firmware,
                    total_firmware,
                );
                return Ok(report);
            }
            Err(err) => {
                if is_non_recoverable_dfu_error(&err) {
                    return Err(err);
                }
                if max_firmware_sent.saturating_sub(attempt_baseline) >= MIN_PAGE_ADVANCE_BYTES {
                    stall_attempts = 0;
                } else {
                    stall_attempts += 1;
                }
                if stall_attempts >= MAX_STALL_ATTEMPTS || total_attempts >= MAX_TOTAL_ATTEMPTS {
                    return Err(err);
                }
                let pct = dfu_percent_from_sent(max_firmware_sent, total_firmware);
                on_progress(
                    pct,
                    "蓝牙传输受阻，正在自动重连断点续传…",
                    max_firmware_sent,
                    total_firmware,
                );
                tokio::time::sleep(DFU_RECONNECT_PAUSE).await;
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Mutex;
    use tokio::sync::mpsc;

    const OP_CREATE: u8 = 0x01;
    const OP_SET_PRN: u8 = 0x02;
    const OP_CALCULATE_CRC: u8 = 0x03;
    const OP_EXECUTE: u8 = 0x04;
    const OP_SELECT: u8 = 0x06;
    const OP_RESPONSE: u8 = 0x60;

    const OBJ_COMMAND: u8 = 0x01;
    const MAX_OBJ_SIZE: usize = 4096;

    struct SimBootloaderState {
        prn: u16,
        selected: u8,
        cmd_committed: bool,
        cmd_buf: Vec<u8>,
        fw_committed: Vec<u8>,
        fw_staging: Vec<u8>,
        fw_staging_target_len: usize,
        packets_since_prn: u16,
        reject_execute_with_ext_err: Option<u8>,
    }

    impl SimBootloaderState {
        fn new(reject_execute_with_ext_err: Option<u8>) -> Self {
            Self {
                prn: 0,
                selected: OBJ_COMMAND,
                cmd_committed: false,
                cmd_buf: Vec::new(),
                fw_committed: Vec::new(),
                fw_staging: Vec::new(),
                fw_staging_target_len: 0,
                packets_since_prn: 0,
                reject_execute_with_ext_err,
            }
        }

        fn active_crc(&self) -> (u32, u32) {
            if self.selected == OBJ_COMMAND {
                let mut h = crc32fast::Hasher::new();
                h.update(&self.cmd_buf);
                (self.cmd_buf.len() as u32, h.finalize())
            } else {
                let mut h = crc32fast::Hasher::new();
                h.update(&self.fw_committed);
                h.update(&self.fw_staging);
                let total_len = (self.fw_committed.len() + self.fw_staging.len()) as u32;
                (total_len, h.finalize())
            }
        }
    }

    struct SimTransport {
        state: Arc<Mutex<SimBootloaderState>>,
        tx: Mutex<Option<mpsc::UnboundedSender<SdkResult<Vec<u8>>>>>,
        rx: Mutex<Option<mpsc::UnboundedReceiver<SdkResult<Vec<u8>>>>>,
        stall_after_packets: Option<usize>,
        packets_written: std::sync::atomic::AtomicUsize,
    }

    impl SimTransport {
        fn new(state: Arc<Mutex<SimBootloaderState>>, stall_after_packets: Option<usize>) -> Self {
            let (tx, rx) = mpsc::unbounded_channel();
            Self {
                state,
                tx: Mutex::new(Some(tx)),
                rx: Mutex::new(Some(rx)),
                stall_after_packets,
                packets_written: std::sync::atomic::AtomicUsize::new(0),
            }
        }

        fn emit(&self, frame: Vec<u8>) {
            if let Some(tx) = self.tx.lock().unwrap().as_ref() {
                let _ = tx.send(Ok(frame));
            }
        }
    }

    #[async_trait]
    impl DfuTransport for SimTransport {
        async fn write_control(&self, bytes: &[u8]) -> SdkResult<()> {
            let mut st = self.state.lock().unwrap();
            let op = bytes[0];
            let reply = match op {
                OP_SET_PRN => {
                    st.prn = u16::from_le_bytes([bytes[1], bytes[2]]);
                    st.packets_since_prn = 0;
                    vec![OP_RESPONSE, OP_SET_PRN, 0x01]
                }
                OP_SELECT => {
                    st.selected = bytes[1];
                    let (offset, crc) = st.active_crc();
                    let mut out = vec![OP_RESPONSE, OP_SELECT, 0x01];
                    let max_sz = if st.selected == OBJ_COMMAND {
                        256u32
                    } else {
                        MAX_OBJ_SIZE as u32
                    };
                    out.extend_from_slice(&max_sz.to_le_bytes());
                    out.extend_from_slice(&offset.to_le_bytes());
                    out.extend_from_slice(&crc.to_le_bytes());
                    out
                }
                OP_CREATE => {
                    st.selected = bytes[1];
                    let sz = u32::from_le_bytes([bytes[2], bytes[3], bytes[4], bytes[5]]) as usize;
                    st.packets_since_prn = 0;
                    if st.selected == OBJ_COMMAND {
                        st.cmd_buf.clear();
                    } else {
                        st.fw_staging.clear();
                        st.fw_staging_target_len = sz;
                    }
                    vec![OP_RESPONSE, OP_CREATE, 0x01]
                }
                OP_CALCULATE_CRC => {
                    let (offset, crc) = st.active_crc();
                    let mut out = vec![OP_RESPONSE, OP_CALCULATE_CRC, 0x01];
                    out.extend_from_slice(&offset.to_le_bytes());
                    out.extend_from_slice(&crc.to_le_bytes());
                    out
                }
                OP_EXECUTE => {
                    if st.selected == OBJ_COMMAND {
                        if let Some(ext) = st.reject_execute_with_ext_err {
                            vec![OP_RESPONSE, OP_EXECUTE, 0x0B, ext]
                        } else {
                            st.cmd_committed = true;
                            vec![OP_RESPONSE, OP_EXECUTE, 0x01]
                        }
                    } else {
                        let chunk = std::mem::take(&mut st.fw_staging);
                        st.fw_committed.extend_from_slice(&chunk);
                        vec![OP_RESPONSE, OP_EXECUTE, 0x01]
                    }
                }
                _ => vec![OP_RESPONSE, op, 0x02],
            };
            drop(st);
            self.emit(reply);
            Ok(())
        }

        async fn write_packet(&self, bytes: &[u8]) -> SdkResult<()> {
            let n = self
                .packets_written
                .fetch_add(1, std::sync::atomic::Ordering::SeqCst)
                + 1;
            if self.stall_after_packets.is_some_and(|limit| n > limit) {
                return Err(CardSdkError::Timeout {
                    command: "DFU packet write".into(),
                    seconds: 3,
                });
            }
            let prn_reply = {
                let mut st = self.state.lock().unwrap();
                if st.selected == OBJ_COMMAND {
                    st.cmd_buf.extend_from_slice(bytes);
                } else {
                    st.fw_staging.extend_from_slice(bytes);
                }
                st.packets_since_prn += 1;
                if st.prn != 0 && st.packets_since_prn == st.prn {
                    st.packets_since_prn = 0;
                    let (offset, crc) = st.active_crc();
                    let mut out = vec![OP_RESPONSE, OP_CALCULATE_CRC, 0x01];
                    out.extend_from_slice(&offset.to_le_bytes());
                    out.extend_from_slice(&crc.to_le_bytes());
                    Some(out)
                } else {
                    None
                }
            };
            if let Some(frame) = prn_reply {
                self.emit(frame);
            }
            Ok(())
        }

        async fn notifications(&self) -> SdkResult<NotificationStream> {
            let rx = self.rx.lock().unwrap().take().expect("notifications once");
            Ok(Box::pin(async_stream_from_rx(rx)))
        }

        async fn disconnect(&self) -> SdkResult<()> {
            let _ = self.tx.lock().unwrap().take();
            Ok(())
        }
    }

    fn async_stream_from_rx(
        mut rx: mpsc::UnboundedReceiver<SdkResult<Vec<u8>>>,
    ) -> impl futures::Stream<Item = SdkResult<Vec<u8>>> + Send {
        futures::stream::poll_fn(move |cx| rx.poll_recv(cx))
    }

    #[tokio::test]
    async fn resumes_from_committed_4kb_boundary_after_write_timeout() {
        let init_packet = vec![0xA5; 64];
        let firmware: Vec<u8> = (0..10_000).map(|i| (i % 251) as u8).collect();
        let package = DfuPackage::from_parts(init_packet, firmware.clone()).unwrap();
        let options = DfuOptions::default();

        let state = Arc::new(Mutex::new(SimBootloaderState::new(None)));
        let mut connect_attempts = 0u32;
        let mut progress_log: Vec<(u8, String, usize)> = Vec::new();

        let report = run_dfu_upload_with_resume(
            &package,
            &options,
            |attempt| {
                connect_attempts = attempt;
                let st = state.clone();
                async move {
                    // Attempt 1 stalls mid-way through object 2 (~4KB + several packets)
                    let limit = if attempt == 1 { Some(220) } else { None };
                    let transport: SharedDfuTransport = Arc::new(SimTransport::new(st, limit));
                    DfuTarget::new(transport).await
                }
            },
            |pct, text, sent, _| {
                progress_log.push((pct, text.to_string(), sent));
            },
        )
        .await
        .expect("DFU resume should complete cleanly");

        assert_eq!(connect_attempts, 2);
        assert!(
            report.resumed_from >= 4096,
            "expected resume >= 4096, got {}",
            report.resumed_from
        );
        assert_eq!(state.lock().unwrap().fw_committed, firmware);
        assert!(
            progress_log
                .iter()
                .any(|(_, text, _)| text.contains("断点续传")),
            "expected resume status message, got {progress_log:?}"
        );
        for pair in progress_log.windows(2) {
            assert!(
                pair[1].0 >= pair[0].0,
                "progress percentage regressed: {:?} -> {:?}",
                pair[0],
                pair[1]
            );
        }
    }

    #[tokio::test]
    async fn aborts_immediately_without_retry_on_extended_error() {
        let package = DfuPackage::from_parts(vec![0x11; 32], vec![0x22; 4096]).unwrap();
        let options = DfuOptions::default();
        let state = Arc::new(Mutex::new(SimBootloaderState::new(Some(0x05))));
        let mut connect_attempts = 0u32;

        let err = run_dfu_upload_with_resume(
            &package,
            &options,
            |attempt| {
                connect_attempts = attempt;
                let st = state.clone();
                async move {
                    let transport: SharedDfuTransport = Arc::new(SimTransport::new(st, None));
                    DfuTarget::new(transport).await
                }
            },
            |_, _, _, _| {},
        )
        .await
        .expect_err("signature failure should abort immediately");

        assert_eq!(connect_attempts, 1);
        assert!(matches!(err, CardSdkError::Dfu { result: 0x0B, .. }));
    }
}
