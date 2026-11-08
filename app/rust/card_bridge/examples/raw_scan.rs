//! 诊断：不做服务过滤，直接看附近 BLE 广播里有什么。
//! 用来确认录音卡的广播包是否包含 NUS 服务 UUID（SDK 的扫描按该 UUID 过滤）。
//!
//! cargo run --release --example raw_scan
use std::time::Duration;

use btleplug::api::{Central, Manager as _, Peripheral as _, ScanFilter};
use btleplug::platform::Manager;

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let manager = Manager::new().await?;
    let adapters = manager.adapters().await?;
    let adapter = adapters.into_iter().next().ok_or("no BLE adapter")?;
    println!("adapter: {:?}", adapter.adapter_info().await?);

    adapter.start_scan(ScanFilter::default()).await?;
    tokio::time::sleep(Duration::from_secs(10)).await;
    adapter.stop_scan().await?;

    let peripherals = adapter.peripherals().await?;
    println!("发现 {} 个设备", peripherals.len());
    for p in peripherals {
        let Ok(Some(props)) = p.properties().await else { continue };
        let name = props.local_name.unwrap_or_default();
        let services: Vec<String> = props.services.iter().map(|u| u.to_string()).collect();
        let is_candidate = name.to_ascii_uppercase().starts_with("DYJ");
        println!(
            "{}name={:?} id={} rssi={:?} services={:?}",
            if is_candidate { ">>> " } else { "" },
            name,
            p.id(),
            props.rssi,
            services
        );
    }
    Ok(())
}
