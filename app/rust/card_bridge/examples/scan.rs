//! 真硬件扫描/连接冒烟：cargo run --release --example scan
use std::time::Duration;

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let manager = reai_card_sdk::DeviceManager::new().await?;
    println!("scanning 6s ...");
    let devices = manager.scan(Duration::from_secs(6)).await?;
    for d in &devices {
        println!("found: name={} id={} rssi={:?}", d.name, d.id, d.rssi);
    }
    let Some(dev) = devices.into_iter().next() else {
        println!("no DYJ device found");
        return Ok(());
    };
    println!("connecting {} ...", dev.id);
    let card = manager.connect(&dev).await?;
    let battery = card.battery().await?;
    let state = card.state().await?;
    let info = card.device_info().await?;
    println!("CONNECTED battery={:?}", battery);
    println!("state={:?}", state);
    println!("info={:?}", info);
    card.disconnect().await?;
    println!("disconnected");
    Ok(())
}
