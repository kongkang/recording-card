//! 诊断：直连一台录音卡，把录音相关命令的真实行为逐条打出来。
//!
//! 目的：App 里点"录音"总是报 code -2，先在这里确认设备到底接受什么、
//! 拒绝什么、拒绝时的完整回包长什么样，再决定 App 怎么改。
//!
//! cargo run --release --example record_probe -- DYJV2_TTU520
use std::time::Duration;

use reai_card_sdk::DeviceManager;
use serde_json::json;

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let want = std::env::args().nth(1).unwrap_or_default();
    if want.is_empty() {
        eprintln!("用法: record_probe <设备名前缀或全名，如 DYJV2_TTU520>");
        std::process::exit(2);
    }

    let manager = DeviceManager::new().await?;
    println!("扫描中…");
    let devices = manager.scan(Duration::from_secs(6)).await?;
    let target = devices
        .iter()
        .find(|d| d.name.eq_ignore_ascii_case(&want) || d.name.contains(&want))
        .cloned()
        .ok_or_else(|| format!("没找到 {want}；扫描到：{:?}", devices.iter().map(|d| &d.name).collect::<Vec<_>>()))?;
    println!("连接 {} ({})", target.name, target.id);

    let device = manager.connect(&target).await?;
    println!("已连接，时间已同步\n");

    // 1) 连接后的初始状态
    // 先拿原始回包：设备字段可能与 SDK 严格解析对不上（缺 bootType 就会整条失败）
    match device.raw_command("STATE_INFO", None).await {
        Ok(raw) => println!("STATE_INFO(raw): {raw}"),
        Err(e) => println!("STATE_INFO(raw) ERR: {e}"),
    }
    match device.raw_command("RECORD_STATUS", None).await {
        Ok(raw) => println!("RECORD_STATUS(raw): {raw}"),
        Err(e) => println!("RECORD_STATUS(raw) ERR: {e}"),
    }
    match device.state().await {
        Ok(state) => println!("STATE_INFO(typed): {}", serde_json::to_string(&state)?),
        Err(e) => println!("STATE_INFO(typed) ERR: {e}"),
    }
    match device.record_status().await {
        Ok(r) => println!("RECORD_STATUS: {}", serde_json::to_string(&r)?),
        Err(e) => println!("RECORD_STATUS ERR: {e}"),
    }
    let storage = device.storage().await;
    println!("STORAGE: {storage:?}");
    let battery = device.battery().await;
    println!("BATTERY: {battery:?}\n");

    // 2) 原始命令探针：看设备对每条命令回的 code
    for (cmd, payload) in [
        ("RECORD", None),
        ("RECORD", None),
    ] {
        let result = device.raw_command(cmd, payload.clone()).await;
        match &result {
            Ok(v) => println!("{cmd} -> OK {v}"),
            Err(e) => println!("{cmd} -> ERR {e}"),
        }
        tokio::time::sleep(Duration::from_millis(800)).await;
        if let Ok(status) = device.record_status().await {
            println!("  之后状态: {}", serde_json::to_string(&status)?);
        }
    }

    // 3) 修复方案验证：绕过 SDK 的 require_sd_on_nrf，直接发 RECORD_START/STOP
    println!("\n-- 修复方案：raw RECORD_START --");
    match device.raw_command("RECORD_START", None).await {
        Ok(v) => println!("raw START OK {v}"),
        Err(e) => println!("raw START ERR {e}"),
    }
    tokio::time::sleep(Duration::from_millis(800)).await;
    if let Ok(s) = device.record_status().await {
        println!("RECORD_STATUS after start: {}", serde_json::to_string(&s)?);
    }

    println!("\n-- 修复方案：raw RECORD_STOP --");
    match device.raw_command("RECORD_STOP", None).await {
        Ok(v) => println!("raw STOP OK {v}"),
        Err(e) => println!("raw STOP ERR {e}"),
    }
    tokio::time::sleep(Duration::from_millis(800)).await;
    if let Ok(s) = device.record_status().await {
        println!("RECORD_STATUS after stop: {}", serde_json::to_string(&s)?);
    }

    // 4) 实时流开关是否影响录音命令
    println!("\n-- RECORD_REALTIME_ENABLE true --");
    match device.set_realtime_enabled(true).await {
        Ok(v) => println!("realtime on OK {v:?}"),
        Err(e) => println!("realtime on ERR {e}"),
    }
    tokio::time::sleep(Duration::from_millis(500)).await;
    println!("-- 开着实时流再 start --");
    match device.raw_command("RECORD_START", None).await {
        Ok(v) => println!("raw START(实时流开) OK {v}"),
        Err(e) => println!("raw START(实时流开) ERR {e}"),
    }
    tokio::time::sleep(Duration::from_millis(1500)).await;
    if let Ok(s) = device.record_status().await {
        println!("RECORD_STATUS: {}", serde_json::to_string(&s)?);
    }
    println!("-- 收尾 stop + 关实时流 --");
    let _ = device.raw_command("RECORD_STOP", None).await;
    let _ = device.set_realtime_enabled(false).await;

    device.disconnect().await.ok();
    println!("\n已断开");
    let _ = json!({});
    Ok(())
}
