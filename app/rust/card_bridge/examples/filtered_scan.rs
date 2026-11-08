//! 诊断：用与 SDK 完全相同的服务过滤再扫一次，对比「过滤」与「不过滤」的差异。
use std::str::FromStr;
use std::time::Duration;

use btleplug::api::{Central, Manager as _, Peripheral as _, ScanFilter};
use btleplug::platform::Manager;
use uuid::Uuid;

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let nus = Uuid::from_str("6e400001-b5a3-f393-e0a9-e50e24dcca9e")?;
    let manager = Manager::new().await?;
    let adapter = manager.adapters().await?.into_iter().next().ok_or("no adapter")?;

    for (label, filter) in [
        ("按 NUS 服务过滤", ScanFilter { services: vec![nus] }),
        ("不过滤", ScanFilter::default()),
    ] {
        adapter.start_scan(filter).await?;
        tokio::time::sleep(Duration::from_secs(8)).await;
        adapter.stop_scan().await?;
        let mut hits = Vec::new();
        for p in adapter.peripherals().await? {
            let Ok(Some(props)) = p.properties().await else { continue };
            let name = props.local_name.unwrap_or_default();
            if name.to_ascii_uppercase().starts_with("DYJ") {
                hits.push(format!("{name}(rssi={:?})", props.rssi));
            }
        }
        println!("[{label}] DYJ 设备 {}: {:?}", hits.len(), hits);
    }
    Ok(())
}
