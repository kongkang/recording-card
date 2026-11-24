//! 硬件类型识别与统一能力矩阵（对齐 `docs/MULTI-DEVICE-ARCHITECTURE.md`）。

use std::collections::HashMap;

use reai_ext_sdk::{RecorderSdkDriver, SdkCapabilities};
use reai_feishu_sdk::FeishuSdkDriver;
use reai_iflytek_sdk::IflytekSdkDriver;
use reai_omi_sdk::OmiSdkDriver;
use serde::{Deserialize, Serialize};
use uuid::Uuid;

/// 支持的硬件设备家族。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum DeviceKind {
    /// 录音卡 V2（`reai-card-sdk`，广播前缀 `DYJV2_`）
    CardV2,
    /// 点一机 V1（`reai-dyj-sdk`，广播前缀 `DYJ_`，不含 `DYJV2_`）
    DyjV1,
    /// 语音 AI 键盘 V2.1（`reai-board-sdk`，广播前缀 `REAI_VB_`）
    BoardV21,
    /// Omi 量产版 / Friend Pendant（`reai-omi-sdk`）
    OmiCv1,
    /// 飞书录音豆 / soundcore Work D3200（`reai-feishu-sdk`）
    FeishuD3200,
    /// 讯飞智能录音笔 A1（`reai-iflytek-sdk`）
    IflytekA1,
}

impl DeviceKind {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::CardV2 => "card_v2",
            Self::DyjV1 => "dyj_v1",
            Self::BoardV21 => "board_v21",
            Self::OmiCv1 => "omi_cv1",
            Self::FeishuD3200 => "feishu_d3200",
            Self::IflytekA1 => "iflytek_a1",
        }
    }

    pub fn display_model(self) -> &'static str {
        match self {
            Self::CardV2 => "录音卡 V2",
            Self::DyjV1 => "点一机 V1",
            Self::BoardV21 => "语音AI键盘 V2.1",
            Self::OmiCv1 => "Omi 录音器",
            Self::FeishuD3200 => "飞书录音豆",
            Self::IflytekA1 => "讯飞智能录音笔 A1",
        }
    }

    pub fn from_hint(kind_hint: Option<&str>, name_hint: Option<&str>) -> Option<Self> {
        match kind_hint {
            Some("card_v2") => return Some(Self::CardV2),
            Some("dyj_v1") => return Some(Self::DyjV1),
            Some("board_v21") => return Some(Self::BoardV21),
            Some("omi_cv1") => return Some(Self::OmiCv1),
            Some("feishu_d3200") => return Some(Self::FeishuD3200),
            Some("iflytek_a1") => return Some(Self::IflytekA1),
            _ => {}
        }
        name_hint.and_then(|n| classify_ble_name(n).map(|(k, _)| k))
    }

    pub fn capabilities(self) -> HardwareCapabilities {
        match self {
            Self::CardV2 => HardwareCapabilities {
                realtime_audio: true,
                has_onboard_storage: true,
                has_file_sync: true,
                has_wifi_config: true,
                has_camera_media: false,
                has_physical_record_toggle: true,
                has_remote_record_control: true,
                has_mark_button: true,
                has_configurable_buttons: true,
                has_configurable_switch: true,
                has_oled_display: true,
                has_standalone_realtime_stream: false,
                has_device_restart: true,
                has_device_shutdown: true,
                has_speaker: false,
                ota_mode: "dual_chip",
            },
            Self::DyjV1 => HardwareCapabilities {
                realtime_audio: true,
                has_onboard_storage: true,
                has_file_sync: true,
                has_wifi_config: true,
                has_camera_media: true,
                has_physical_record_toggle: true,
                has_remote_record_control: true,
                has_mark_button: false,
                has_configurable_buttons: true,
                has_configurable_switch: false,
                has_oled_display: false,
                has_standalone_realtime_stream: true,
                has_device_restart: true,
                has_device_shutdown: false,
                has_speaker: true,
                ota_mode: "single_ota",
            },
            Self::BoardV21 => HardwareCapabilities {
                realtime_audio: true,
                has_onboard_storage: false,
                has_file_sync: false,
                has_wifi_config: false,
                has_camera_media: false,
                has_physical_record_toggle: true,
                has_remote_record_control: true,
                has_mark_button: false,
                has_configurable_buttons: false,
                has_configurable_switch: false,
                has_oled_display: false,
                has_standalone_realtime_stream: true,
                has_device_restart: false,
                has_device_shutdown: false,
                has_speaker: false,
                ota_mode: "none",
            },
            Self::OmiCv1 => HardwareCapabilities::from_sdk(OmiSdkDriver.default_capabilities()),
            Self::FeishuD3200 => {
                HardwareCapabilities::from_sdk(FeishuSdkDriver.default_capabilities())
            }
            Self::IflytekA1 => {
                HardwareCapabilities::from_sdk(IflytekSdkDriver.default_capabilities())
            }
        }
    }
}

/// 暴露给 Flutter UI 与调度层的能力位（UI 严禁硬编码型号名，一律读能力裁剪）。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct HardwareCapabilities {
    pub realtime_audio: bool,
    pub has_onboard_storage: bool,
    pub has_file_sync: bool,
    pub has_wifi_config: bool,
    pub has_camera_media: bool,
    pub has_physical_record_toggle: bool,
    pub has_remote_record_control: bool,
    pub has_mark_button: bool,
    pub has_configurable_buttons: bool,
    pub has_configurable_switch: bool,
    pub has_oled_display: bool,
    pub has_standalone_realtime_stream: bool,
    pub has_device_restart: bool,
    pub has_device_shutdown: bool,
    pub has_speaker: bool,
    /// `"dual_chip"` | `"single_ota"` | `"none"`
    pub ota_mode: &'static str,
}

impl HardwareCapabilities {
    pub fn from_sdk(caps: SdkCapabilities) -> Self {
        Self {
            realtime_audio: caps.realtime_audio,
            has_onboard_storage: caps.has_onboard_storage,
            has_file_sync: caps.has_file_sync,
            has_wifi_config: caps.has_wifi_config,
            has_camera_media: caps.has_camera_media,
            has_physical_record_toggle: caps.has_physical_record_toggle,
            has_remote_record_control: caps.has_remote_record_control,
            has_mark_button: caps.has_mark_button,
            has_configurable_buttons: caps.has_configurable_buttons,
            has_configurable_switch: false,
            has_oled_display: false,
            has_standalone_realtime_stream: caps.realtime_audio,
            has_device_restart: false,
            has_device_shutdown: false,
            has_speaker: false,
            ota_mode: caps.ota_mode,
        }
    }
}

const DFU_FE59_SERVICE_UUID: Uuid = Uuid::from_u128(0x0000fe59_0000_1000_8000_00805f9b34fb);

/// 按点一机 V1 实机协商的版本码与 `feature_bits` 动态裁剪能力矩阵。
///
/// - `< 0.8.8`（`version_code` in `1..808`）固件无 `camera.*` 域，`has_camera_media = false`；
/// - `>= 0.8.8`（或未知 `0`）保留 `has_camera_media = true`。
pub fn dyj_v1_capabilities_for_firmware(
    fw_version_code: u64,
    feature_bits: Option<u64>,
) -> HardwareCapabilities {
    let mut caps = DeviceKind::DyjV1.capabilities();
    if fw_version_code > 0 && fw_version_code < 808 {
        caps.has_camera_media = false;
    }
    if let Some(bits) = feature_bits {
        if bits & 0x04 == 0 {
            caps.realtime_audio = false;
        }
    }
    caps
}

/// V2 录音卡 Bootloader 恢复模式（`DFU_DYJ` / `0xFE59`）能力裁剪：仅允许固件恢复升级。
pub fn card_v2_dfu_recovery_capabilities() -> HardwareCapabilities {
    HardwareCapabilities {
        realtime_audio: false,
        has_onboard_storage: false,
        has_file_sync: false,
        has_wifi_config: false,
        has_camera_media: false,
        has_physical_record_toggle: false,
        has_remote_record_control: false,
        has_mark_button: false,
        has_configurable_buttons: false,
        has_configurable_switch: false,
        has_oled_display: false,
        has_standalone_realtime_stream: false,
        has_device_restart: false,
        has_device_shutdown: false,
        has_speaker: false,
        ota_mode: "dual_chip",
    }
}

pub fn is_card_v2_dfu_advertisement(local_name: Option<&str>, services: &[Uuid]) -> bool {
    let clean = local_name.map(str::trim).filter(|s| !s.is_empty());
    if clean.is_some_and(|n| n.to_ascii_uppercase().starts_with("DFU_DYJ")) {
        return true;
    }
    services.contains(&DFU_FE59_SERVICE_UUID)
        && clean.is_none_or(|n| n.to_ascii_uppercase().starts_with("DFU"))
}

fn classify_proprietary_name(trimmed: &str) -> Option<(DeviceKind, HardwareCapabilities)> {
    let upper = trimmed.to_ascii_uppercase();
    if upper.starts_with("DYJV2_") {
        Some((DeviceKind::CardV2, DeviceKind::CardV2.capabilities()))
    } else if upper.starts_with("DYJ_") || upper.starts_with("DYJ-") {
        Some((DeviceKind::DyjV1, DeviceKind::DyjV1.capabilities()))
    } else if upper.starts_with("REAI_VB_") {
        Some((DeviceKind::BoardV21, DeviceKind::BoardV21.capabilities()))
    } else if upper.starts_with("DFU_DYJ") {
        Some((DeviceKind::CardV2, card_v2_dfu_recovery_capabilities()))
    } else {
        None
    }
}

fn external_drivers() -> [&'static dyn RecorderSdkDriver; 3] {
    [&OmiSdkDriver, &FeishuSdkDriver, &IflytekSdkDriver]
}

/// 根据 BLE 广播名称识别支持的录音硬件。
///
/// 注意顺序：`DYJV2_` 必须在 `DYJ_` 之前判断，避免把二代录音卡误判成一代点一机。
pub fn classify_ble_name(name: &str) -> Option<(DeviceKind, HardwareCapabilities)> {
    let trimmed = name.trim();
    if trimmed.is_empty() {
        return None;
    }
    if let Some(hit) = classify_proprietary_name(trimmed) {
        return Some(hit);
    }
    let empty_mfd = HashMap::new();
    for drv in external_drivers() {
        if drv.matches_advertisement(Some(trimmed), &[], &empty_mfd) {
            if let Some(kind) = DeviceKind::from_hint(Some(drv.device_kind()), None) {
                return Some((kind, HardwareCapabilities::from_sdk(drv.default_capabilities())));
            }
        }
    }
    None
}

/// 综合广播本地名、128-bit 服务 UUID 与厂商广播数据识别支持的硬件（支持纯 UUID 广播的 Omi）。
pub fn classify_ble_advertisement(
    peripheral_id: &str,
    local_name: Option<&str>,
    services: &[Uuid],
    manufacturer_data: &HashMap<u16, Vec<u8>>,
) -> Option<(String, DeviceKind, HardwareCapabilities)> {
    let clean_name = local_name.map(str::trim).filter(|s| !s.is_empty());
    if let Some(name) = clean_name {
        if let Some((kind, caps)) = classify_proprietary_name(name) {
            return Some((name.to_string(), kind, caps));
        }
    }
    if is_card_v2_dfu_advertisement(clean_name, services) {
        return Some((
            "DFU_DYJ".to_string(),
            DeviceKind::CardV2,
            card_v2_dfu_recovery_capabilities(),
        ));
    }
    for drv in external_drivers() {
        if drv.matches_advertisement(clean_name, services, manufacturer_data) {
            let kind = DeviceKind::from_hint(Some(drv.device_kind()), None)?;
            let display_name = clean_name
                .map(str::to_owned)
                .unwrap_or_else(|| drv.fallback_ble_name(peripheral_id));
            return Some((
                display_name,
                kind,
                HardwareCapabilities::from_sdk(drv.default_capabilities()),
            ));
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;
    use reai_omi_sdk::protocol::{SVC_FRIEND_PENDANT_UUID, SVC_OMI_AUDIO_UUID};

    #[test]
    fn classifies_all_three_hardware_families_without_prefix_collision() {
        let (k2, c2) = classify_ble_name("DYJV2_T4W25T").expect("card v2");
        assert_eq!(k2, DeviceKind::CardV2);
        assert!(c2.has_onboard_storage && c2.has_file_sync && !c2.has_camera_media);
        assert!(
            c2.has_remote_record_control
                && c2.has_configurable_buttons
                && c2.has_configurable_switch
                && c2.has_oled_display
                && !c2.has_standalone_realtime_stream
                && c2.has_device_restart
                && c2.has_device_shutdown
        );
        assert_eq!(c2.ota_mode, "dual_chip");

        let (k1, c1) = classify_ble_name("DYJ_RA6BO5").expect("dyj v1");
        assert_eq!(k1, DeviceKind::DyjV1);
        assert!(c1.has_onboard_storage && c1.has_camera_media);
        assert!(
            c1.has_remote_record_control
                && c1.has_configurable_buttons
                && c1.has_device_restart
                && !c1.has_device_shutdown
        );
        assert_eq!(c1.ota_mode, "single_ota");

        for gen1_name in ["DYJ-Ab12Cd", "DYJ-V1", "dyj_abc123", "dyj-998877"] {
            let (kg1, cg1) = classify_ble_name(gen1_name).expect("dyj v1 gen1");
            assert_eq!(kg1, DeviceKind::DyjV1);
            assert!(cg1.has_onboard_storage && cg1.has_camera_media);
        }

        let (kb, cb) = classify_ble_name("REAI_VB_A91C").expect("board v2.1");
        assert_eq!(kb, DeviceKind::BoardV21);
        assert!(cb.realtime_audio && cb.has_remote_record_control);
        assert!(
            !cb.has_onboard_storage
                && !cb.has_file_sync
                && !cb.has_wifi_config
                && !cb.has_device_restart
                && !cb.has_device_shutdown
        );
        assert_eq!(cb.ota_mode, "none");

        assert!(classify_ble_name("JBL Flip 6").is_none());
        assert!(classify_ble_name("").is_none());
    }

    #[test]
    fn classifies_omi_and_feishu_by_name_and_uuid() {
        let empty = HashMap::new();

        assert!(classify_ble_name("Get-A102").is_none());

        let (name_omi, ko, co) =
            classify_ble_advertisement("dead-beef-5678", None, &[SVC_OMI_AUDIO_UUID], &empty)
                .expect("omi uuid only");
        assert_eq!(ko, DeviceKind::OmiCv1);
        assert!(co.realtime_audio && co.has_file_sync && co.has_remote_record_control);
        assert!(
            co.has_mark_button
                && co.has_configurable_buttons
                && !co.has_wifi_config
                && !co.has_device_restart
                && !co.has_device_shutdown
        );
        assert!(name_omi.starts_with("Omi-"));

        let (_, kf, _) = classify_ble_advertisement(
            "cafe-9999",
            Some("Friend_9999"),
            &[SVC_FRIEND_PENDANT_UUID],
            &empty,
        )
        .expect("friend pendant");
        assert_eq!(kf, DeviceKind::OmiCv1);

        let (name_bean, kb, cb) = classify_ble_advertisement(
            "aabb-c3a1",
            None,
            &[reai_feishu_sdk::SERVICE_UUID],
            &empty,
        )
        .expect("feishu uuid only");
        assert_eq!(kb, DeviceKind::FeishuD3200);
        assert!(name_bean.starts_with("D3200-"));
        assert!(cb.has_file_sync && cb.has_remote_record_control && cb.has_physical_record_toggle);
        assert!(
            !cb.realtime_audio
                && !cb.has_wifi_config
                && !cb.has_mark_button
                && !cb.has_device_restart
                && !cb.has_device_shutdown
        );
        assert_eq!(cb.ota_mode, "none");

        let (kn, _) = classify_ble_name("D3200-C3A1").expect("feishu name");
        assert_eq!(kn, DeviceKind::FeishuD3200);

        let (ka_name, ka, ca) = classify_ble_advertisement(
            "11e0-a1",
            Some("讯飞录音笔A1_11E0"),
            &[],
            &empty,
        )
        .expect("iflytek a1 name");
        assert_eq!(ka_name, "讯飞录音笔A1_11E0");
        assert_eq!(ka, DeviceKind::IflytekA1);
        assert!(ca.realtime_audio && ca.has_file_sync && ca.has_remote_record_control);
        assert!(ca.has_physical_record_toggle && !ca.has_wifi_config && !ca.has_mark_button);
        assert_eq!(ca.ota_mode, "none");

        let mut a1_mfd = HashMap::new();
        a1_mfd.insert(0x3332, b"03051401437265".to_vec());
        let (ka_uuid_name, ka2, _) = classify_ble_advertisement(
            "11e0-uuid",
            None,
            &[reai_iflytek_sdk::SERVICE_UUID],
            &a1_mfd,
        )
        .expect("iflytek a1 uuid");
        assert_eq!(ka2, DeviceKind::IflytekA1);
        assert!(ka_uuid_name.starts_with("讯飞录音笔A1_"));

        let (dfu_name, dfu_kind, dfu_caps) = classify_ble_advertisement(
            "dfu-1",
            Some("DFU_DYJ"),
            &[DFU_FE59_SERVICE_UUID],
            &empty,
        )
        .expect("dfu recovery name");
        assert_eq!(dfu_name, "DFU_DYJ");
        assert_eq!(dfu_kind, DeviceKind::CardV2);
        assert_eq!(dfu_caps.ota_mode, "dual_chip");
        assert!(
            !dfu_caps.realtime_audio
                && !dfu_caps.has_wifi_config
                && !dfu_caps.has_device_restart
                && !dfu_caps.has_device_shutdown
        );

        let (dfu_uuid_only, dfu_uuid_kind, _) =
            classify_ble_advertisement("dfu-2", None, &[DFU_FE59_SERVICE_UUID], &empty)
                .expect("dfu recovery uuid only");
        assert_eq!(dfu_uuid_only, "DFU_DYJ");
        assert_eq!(dfu_uuid_kind, DeviceKind::CardV2);

        let caps_087 = dyj_v1_capabilities_for_firmware(807, Some(31));
        assert!(!caps_087.has_camera_media);
        assert!(caps_087.realtime_audio);
        let caps_0815 = dyj_v1_capabilities_for_firmware(815, Some(255));
        assert!(caps_0815.has_camera_media);
        assert!(caps_0815.realtime_audio);
        assert!(caps_0815.has_speaker);
        assert!(!DeviceKind::CardV2.capabilities().has_speaker);
        assert!(!DeviceKind::BoardV21.capabilities().has_speaker);
        let caps_unknown = dyj_v1_capabilities_for_firmware(0, None);
        assert!(caps_unknown.has_camera_media);
        assert!(caps_unknown.has_speaker);
    }
}
