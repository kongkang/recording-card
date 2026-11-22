//! 讯飞智能录音笔 A1（`iflytek_a1`）安全真机 E2E 验收探针。
//!
//! 严守数据安全约定：
//! - 默认仅执行扫描、建连、对时、快照与只读列举既有文件。
//! - 仅当显式传入 `--live-rw` 时才执行「遥控开录 6s（可配电脑播音）→ 实时 PCM 流统计 → 停录 → 下载该新建短片转 WAV → 仅删除该新建测试片 → 校验既有文件列表 100% 完好」。
//! - 绝不触碰任何既有历史录音。

use std::collections::HashSet;
use std::env;
use std::time::Duration;

use btleplug::api::{Central as _, Manager as _, Peripheral as _, ScanFilter};
use btleplug::platform::Manager;
use reai_ext_sdk::RecorderSdkDriver;
use reai_iflytek_sdk::IflytekSdkDriver;

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let live_rw = env::args().any(|a| a == "--live-rw");
    let manager = Manager::new().await?;
    let adapters = manager.adapters().await?;
    let adapter = adapters.into_iter().next().ok_or("未找到 BLE 适配器")?;

    println!("[probe] 开始扫描讯飞智能录音笔 A1（6 秒）...");
    adapter.start_scan(ScanFilter::default()).await?;
    tokio::time::sleep(Duration::from_secs(6)).await;
    let _ = adapter.stop_scan().await;

    let mut found = None;
    for p in adapter.peripherals().await? {
        if let Ok(Some(props)) = p.properties().await {
            if IflytekSdkDriver.matches_advertisement(
                props.local_name.as_deref(),
                &props.services,
                &props.manufacturer_data,
            ) {
                let name = props
                    .local_name
                    .unwrap_or_else(|| IflytekSdkDriver.fallback_ble_name(&p.id().to_string()));
                found = Some((p, name));
                break;
            }
        }
    }

    let Some((peripheral, ble_name)) = found else {
        println!("[probe] 未扫描到讯飞录音笔 A1（可能已息屏进入 5 分钟自动休眠或正被其他手机占连）");
        return Ok(());
    };
    println!("[probe] 发现目标设备: {ble_name} ({})", peripheral.id());

    let device = IflytekSdkDriver.connect(peripheral, ble_name).await?;
    let snap = device.snapshot().await?;
    println!(
        "[probe] 快照: model={} fw={} bat={:?}% charging={} storage={:?} recording={}",
        snap.capabilities.display_model,
        snap.fw_version,
        snap.battery.level,
        snap.battery.is_charging,
        snap.storage,
        snap.record.is_recording
    );

    let baseline_files = device.list_files().await?;
    let baseline_names: HashSet<String> =
        baseline_files.iter().map(|f| f.name.clone()).collect();
    println!(
        "[probe] 既有文件数={}（全量保护，不修改不删除）",
        baseline_files.len()
    );
    for f in baseline_files.iter().take(10) {
        println!(
            "  - {} ({} bytes, start_at={:?})",
            f.name, f.size, f.start_at
        );
    }

    if live_rw {
        if snap.record.is_recording {
            device.disconnect().await?;
            return Err("设备当前正在录音，为保护现场录音中止测试".into());
        }
        let mut aud_rx = device.subscribe_audio();
        device.set_realtime_enabled(true).await?;
        let st = device.start_record(None).await?;
        let new_file = st.session.clone();
        println!("[probe] 已遥控开录: session={new_file:?}");

        let start = tokio::time::Instant::now();
        let mut rt_samples = 0usize;
        while start.elapsed() < Duration::from_secs(6) {
            if let Ok(Ok(chunk)) =
                tokio::time::timeout(Duration::from_millis(500), aud_rx.recv()).await
            {
                rt_samples += chunk.samples.len();
            }
        }
        println!("[probe] 6s 实时 SBC->PCM 累计采样={rt_samples}");
        device.set_realtime_enabled(false).await?;
        let _ = device.stop_record().await?;
        tokio::time::sleep(Duration::from_secs(1)).await;

        let after_files = device.list_files().await?;
        let created_name = after_files
            .iter()
            .find(|f| !baseline_names.contains(&f.name))
            .map(|f| f.name.clone());
        if let Some(target_name) = created_name {
            println!("[probe] 发现新建测试文件: {target_name}");
            let tmp_dir = std::env::temp_dir().join("iflytek_a1_probe_dl");
            let _ = std::fs::remove_dir_all(&tmp_dir);
            let saved = device
                .download_file(&target_name, tmp_dir.to_str().unwrap())
                .await?;
            println!(
                "[probe] 下载解码 WAV 成功: {:?} ({} bytes)",
                saved.path, saved.bytes_written
            );
            device.delete_file(&target_name).await?;
            let verify_files = device.list_files().await?;
            let verify_names: HashSet<String> =
                verify_files.iter().map(|f| f.name.clone()).collect();
            assert_eq!(
                verify_names, baseline_names,
                "既有文件集合发生意外变化！"
            );
            println!("[probe] 已仅清理新建测试文件并核实既有文件 100% 完好！");
            let _ = std::fs::remove_dir_all(&tmp_dir);
        }
    }

    device.disconnect().await?;
    println!("[probe] 完成并已安全断开蓝牙。");
    Ok(())
}
