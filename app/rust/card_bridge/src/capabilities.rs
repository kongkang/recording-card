//! 硬件类型识别与统一能力矩阵（对齐 `docs/MULTI-DEVICE-ARCHITECTURE.md`）。

use serde::{Deserialize, Serialize};

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
}

impl DeviceKind {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::CardV2 => "card_v2",
            Self::DyjV1 => "dyj_v1",
            Self::BoardV21 => "board_v21",
        }
    }

    pub fn display_model(self) -> &'static str {
        match self {
            Self::CardV2 => "录音卡 V2",
            Self::DyjV1 => "点一机 V1",
            Self::BoardV21 => "语音AI键盘 V2.1",
        }
    }

    pub fn from_hint(kind_hint: Option<&str>, name_hint: Option<&str>) -> Option<Self> {
        match kind_hint {
            Some("card_v2") => return Some(Self::CardV2),
            Some("dyj_v1") => return Some(Self::DyjV1),
            Some("board_v21") => return Some(Self::BoardV21),
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
                has_mark_button: true,
                ota_mode: "dual_chip",
            },
            Self::DyjV1 => HardwareCapabilities {
                realtime_audio: true,
                has_onboard_storage: true,
                has_file_sync: true,
                has_wifi_config: true,
                has_camera_media: true,
                has_physical_record_toggle: true,
                has_mark_button: false,
                ota_mode: "single_ota",
            },
            Self::BoardV21 => HardwareCapabilities {
                realtime_audio: true,
                has_onboard_storage: false,
                has_file_sync: false,
                has_wifi_config: false,
                has_camera_media: false,
                has_physical_record_toggle: true,
                has_mark_button: false,
                ota_mode: "none",
            },
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
    pub has_mark_button: bool,
    /// `"dual_chip"` | `"single_ota"` | `"none"`
    pub ota_mode: &'static str,
}

/// 根据 BLE 广播名称识别支持的录音硬件。
///
/// 注意顺序：`DYJV2_` 必须在 `DYJ_` 之前判断，避免把二代录音卡误判成一代点一机。
pub fn classify_ble_name(name: &str) -> Option<(DeviceKind, HardwareCapabilities)> {
    let trimmed = name.trim();
    if trimmed.starts_with("DYJV2_") {
        Some((DeviceKind::CardV2, DeviceKind::CardV2.capabilities()))
    } else if trimmed.starts_with("DYJ_") {
        Some((DeviceKind::DyjV1, DeviceKind::DyjV1.capabilities()))
    } else if trimmed.starts_with("REAI_VB_") {
        Some((DeviceKind::BoardV21, DeviceKind::BoardV21.capabilities()))
    } else {
        None
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn classifies_all_three_hardware_families_without_prefix_collision() {
        let (k2, c2) = classify_ble_name("DYJV2_T4W25T").expect("card v2");
        assert_eq!(k2, DeviceKind::CardV2);
        assert!(c2.has_onboard_storage && c2.has_file_sync && !c2.has_camera_media);
        assert_eq!(c2.ota_mode, "dual_chip");

        let (k1, c1) = classify_ble_name("DYJ_RA6BO5").expect("dyj v1");
        assert_eq!(k1, DeviceKind::DyjV1);
        assert!(c1.has_onboard_storage && c1.has_camera_media);
        assert_eq!(c1.ota_mode, "single_ota");

        let (kb, cb) = classify_ble_name("REAI_VB_A91C").expect("board v2.1");
        assert_eq!(kb, DeviceKind::BoardV21);
        assert!(cb.realtime_audio);
        assert!(!cb.has_onboard_storage && !cb.has_file_sync && !cb.has_wifi_config);
        assert_eq!(cb.ota_mode, "none");

        assert!(classify_ble_name("JBL Flip 6").is_none());
        assert!(classify_ble_name("").is_none());
    }
}
