//! OTA is deliberately fail-closed: local package + pinned SHA256 + identity +
//! installed/target versions + explicit confirmation. No default OTA endpoint,
//! no first-discovered bootloader, no timer-generated success.
use super::*;
use reai_card_sdk::{DfuOptions, DfuPackage, DfuStage, OtaInfo};
use sha2::{Digest, Sha256};

fn bound_progress(
    req: &Value,
    cb: Callback,
    ticket: usize,
    stage: &str,
    done: Option<u64>,
    total: Option<u64>,
) {
    emit(
        cb,
        ticket,
        json!({"event":{"kind":"progress","stage":stage,"done":done,"total":total,
        "requestTicket":ticket,"deviceId":req["deviceId"],"module":req["module"],
        "packageSha256":req["sha256"],"targetVersionCode":req["targetVersionCode"]}}),
    );
}

pub(crate) fn validate_https(url: &str, req: &Value) -> Result<()> {
    let u = reqwest::Url::parse(url).map_err(|_| Error::new("configuration", "固件URL无效"))?;
    let hosts = req
        .get("allowedHosts")
        .and_then(Value::as_array)
        .ok_or_else(|| Error::new("configuration", "未配置固件host白名单"))?;
    let host = u.host_str().unwrap_or("");
    if u.scheme() != "https"
        || !u.username().is_empty()
        || u.password().is_some()
        || !hosts.iter().any(|h| h.as_str() == Some(host))
    {
        return Err(Error::new(
            "configuration",
            "固件URL必须是白名单内的HTTPS地址，无凭据",
        ));
    }
    Ok(())
}
pub(crate) async fn check(session: &Session, req: &Value) -> Result<Value> {
    let base = text(req, "apiBaseUrl")?;
    validate_https(base, req)?;
    let info = device(session)?.device_info().await?;
    let client = reqwest::Client::builder()
        .redirect(reqwest::redirect::Policy::none())
        .timeout(Duration::from_secs(15))
        .build()
        .map_err(SdkError::from)?;
    let mut updates = Vec::new();
    for (module, installed) in [
        ("main", Some(info.version_code)),
        ("wifi", info.wifi_version_code),
    ] {
        let url = format!("{}/ota/info?mod={module}", base.trim_end_matches('/'));
        let response = client
            .get(&url)
            .send()
            .await
            .map_err(SdkError::from)?
            .error_for_status()
            .map_err(SdkError::from)?;
        let manifest: OtaInfo = response.json().await.map_err(SdkError::from)?;
        validate_https(&manifest.url, req)?;
        updates.push(json!({"module":module,"deviceId":info.device_id,"installedVersionCode":installed,"version":manifest.version,"versionCode":manifest.version_code,"url":manifest.url,"updateAvailable":installed.map(|v|manifest.version_code>v),"requiresPinnedSha256":true}));
    }
    Ok(Value::Array(updates))
}
fn number(req: &Value, key: &str) -> Result<u32> {
    req.get(key)
        .and_then(Value::as_u64)
        .filter(|v| *v <= u32::MAX as u64)
        .map(|v| v as u32)
        .ok_or_else(|| Error::new("argument", format!("缺少整数参数{key}")))
}
fn validate_digest(bytes: &[u8], expected: &str) -> Result<()> {
    if expected.len() != 64 || !expected.bytes().all(|b| b.is_ascii_hexdigit()) {
        return Err(Error::new(
            "configuration",
            "需要由可信固件配置提供64位SHA256，不能从未验证包自签",
        ));
    }
    let actual = format!("{:x}", Sha256::digest(bytes));
    if !actual.eq_ignore_ascii_case(expected) {
        return Err(Error::new("integrity", "固件包SHA256不匹配"));
    }
    Ok(())
}
fn validate_binding(
    info: &reai_card_sdk::DeviceInfo,
    req: &Value,
    transport_id: &str,
) -> Result<()> {
    let module = text(req, "module")?;
    if text(req, "transportId")? != transport_id || text(req, "deviceId")? != info.device_id {
        return Err(Error::new("identity", "固件任务与当前录音卡身份不一致"));
    }
    let current = match module {
        "main" => Some(info.version_code),
        "wifi" => info.wifi_version_code,
        _ => return Err(Error::new("argument", "未知固件模块")),
    };
    let installed = number(req, "installedVersionCode")?;
    if current != Some(installed) {
        return Err(Error::new(
            "version",
            "已装版本与确认的固件任务不一致，请重新检查",
        ));
    }
    if number(req, "targetVersionCode")? <= installed || text(req, "targetVersion")?.is_empty() {
        return Err(Error::new(
            "version",
            "目标版本必须更高，拒绝降级或同版本刷写",
        ));
    }
    Ok(())
}
pub(crate) async fn update(
    session: &mut Session,
    req: &Value,
    cb: Callback,
    ticket: usize,
) -> Result<Value> {
    confirmed(req)?;
    let module = text(req, "module")?.to_owned();
    let path = std::path::Path::new(text(req, "packagePath")?);
    if !path.is_absolute() {
        return Err(Error::new(
            "configuration",
            "需要应用私有目录的已验证本地固件包",
        ));
    }
    let metadata = tokio::fs::metadata(path).await?;
    if metadata.len() == 0 || metadata.len() > 16 * 1024 * 1024 {
        return Err(Error::new("resource", "固件包为空或超过16MiB"));
    }
    let bytes = tokio::fs::read(path).await?;
    validate_digest(&bytes, text(req, "sha256")?)?;
    let c = session
        .connection
        .as_ref()
        .ok_or_else(|| Error::new("disconnected", "录音卡未连接"))?;
    let info = c.device.device_info().await?;
    validate_binding(&info, req, &c.discovered.id)?;
    if c.device.record_status().await?.is_recording {
        return Err(Error::new("busy", "请先停止录音后再更新固件"));
    }
    bound_progress(req, cb, ticket, "packageVerified", None, None);
    match module.as_str() {
        "main" => update_main(session, req, bytes, cb, ticket).await,
        "wifi" => update_wifi(session, req, bytes, cb, ticket).await,
        _ => Err(Error::new("argument", "未知固件模块")),
    }
}
async fn update_main(
    session: &mut Session,
    req: &Value,
    bytes: Vec<u8>,
    cb: Callback,
    ticket: usize,
) -> Result<Value> {
    let dfu_id = text(req, "dfuTargetId")?.to_owned(); // Exact target selected/confirmed beforehand.
    let transport_id = text(req, "transportId")?.to_owned();
    let package = DfuPackage::from_zip_bytes(&bytes)?;
    if device(session)?.state().await?.wifi_open {
        return Err(Error::new("busy", "主控DFU要求先关闭Wi-Fi，归还SD所有权"));
    }
    let manager = DeviceManager::new().await?;
    bound_progress(req, cb, ticket, "enterDfu", None, None);
    device(session)?.enter_dfu_mode().await?;
    close_connection(session).await?;
    let deadline = tokio::time::Instant::now() + Duration::from_secs(30);
    let target = loop {
        if let Some(d) = manager
            .scan_dfu_targets(Duration::from_secs(2))
            .await?
            .into_iter()
            .find(|d| d.id == dfu_id)
        {
            break d;
        }
        if tokio::time::Instant::now() >= deadline {
            return Err(Error::new(
                "identity",
                "没有找到已确认ID的DFU目标；绝不刷写第一个广播设备",
            ));
        }
    };
    let mut job = tokio::spawn(async move { manager.connect_dfu(&target).await });
    let dfu = match tokio::time::timeout(Duration::from_secs(20), &mut job).await {
        Ok(result) => Arc::new(result.map_err(|_| Error::new("protocol", "DFU连接任务异常停止"))??),
        Err(_) => {
            session.recovery = Some(tokio::spawn(async move {
                if let Ok(Ok(dfu)) = job.await {
                    let _ = dfu.disconnect().await;
                }
            }));
            return Err(Error::new("timeout", "DFU连接超时；保留迟到连接的清理任务"));
        }
    };
    session.dfu = Some(Arc::clone(&dfu));
    let result = tokio::time::timeout(
        Duration::from_secs(480),
        dfu.upload(&package, &DfuOptions::default(), |p| {
            bound_progress(
                req,
                cb,
                ticket,
                match p.stage {
                    DfuStage::InitPacket => "dfuInitPacket",
                    DfuStage::Firmware => "dfuFirmware",
                },
                Some(p.sent as u64),
                Some(p.total as u64),
            );
        }),
    )
    .await;
    close_connection(session).await?;
    let report = result.map_err(|_| Error::new("timeout", "DFU传输超时，已尝试断开目标"))??;
    bound_progress(req, cb, ticket, "verifyingInstalledVersion", None, None);
    // Actual reboot/reconnect evidence, not a synthetic timer success. If the
    // user needs to rejoin an AP or authorize reconnect, fail explicitly.
    tokio::time::sleep(Duration::from_secs(3)).await;
    super::connect(session, &transport_id).await?;
    let actual = device(session)?.device_info().await?;
    if actual.device_id != text(req, "deviceId")?
        || actual.version_code != number(req, "targetVersionCode")?
        || actual.version != text(req, "targetVersion")?
    {
        return Err(Error::new(
            "verification",
            "DFU上传结束，但重连后的设备身份/版本未匹配目标；不得显示升级成功",
        ));
    }
    Ok(
        json!({"module":"main","verified":true,"deviceId":actual.device_id,"version":actual.version,"versionCode":actual.version_code,"firmwareBytes":report.firmware_bytes,"rewinds":report.rewinds}),
    )
}
async fn update_wifi(
    session: &Session,
    req: &Value,
    bytes: Vec<u8>,
    cb: Callback,
    ticket: usize,
) -> Result<Value> {
    let d = device(session)?;
    if !d.state().await?.wifi_open {
        return Err(Error::new(
            "apUnavailable",
            "Wi-Fi OTA要求先打开模块并在系统加入卡热点",
        ));
    }
    let client = d.access_point_client().await?;
    let before = client.ota_status().await?;
    if before.chip_model != text(req, "chipModel")?
        || before.current_version_code != number(req, "installedVersionCode")?
        || !before.ota_ready
    {
        return Err(Error::new(
            "identity",
            "Wi-Fi芯片型号/已装版本/OTA就绪状态与确认任务不一致",
        ));
    }
    if bytes.first() != Some(&0xe9) {
        return Err(Error::new("integrity", "Wi-Fi固件不是ESP镜像"));
    }
    bound_progress(
        req,
        cb,
        ticket,
        "wifiUploading",
        None,
        Some(bytes.len() as u64),
    );
    let response = client.upload_firmware(bytes, "wifi-firmware.bin").await?;
    // Older firmware omitting digest cannot provide package-bound verification.
    if response
        .sha256
        .as_deref()
        .is_none_or(|h| !h.eq_ignore_ascii_case(text(req, "sha256").unwrap_or("")))
    {
        return Err(Error::new(
            "verification",
            "设备未返回匹配包SHA256；写入结果未经验证，不能报告成功",
        ));
    }
    bound_progress(req, cb, ticket, "verifyingInstalledVersion", None, None);
    let deadline = tokio::time::Instant::now() + Duration::from_secs(60);
    loop {
        tokio::time::sleep(Duration::from_secs(3)).await;
        // Polling requests read actual hardware; delay is not a success condition.
        if let Ok(actual) = client.ota_status().await {
            if actual.current_version_code == number(req, "targetVersionCode")?
                && actual.current_version == text(req, "targetVersion")?
                && actual.chip_model == before.chip_model
            {
                let info = d.device_info().await?;
                if info.device_id != text(req, "deviceId")? {
                    return Err(Error::new("identity", "OTA后设备身份变化"));
                }
                return Ok(
                    json!({"module":"wifi","verified":true,"deviceId":info.device_id,"version":actual.current_version,"versionCode":actual.current_version_code,"sha256":response.sha256}),
                );
            }
        }
        if tokio::time::Instant::now() >= deadline {
            return Err(Error::new(
                "verification",
                "Wi-Fi写入已完成，但重启后未验证目标版本；请重新加入卡热点并检查",
            ));
        }
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn hash_rejects_wrong_package() {
        assert!(validate_digest(b"a", &"0".repeat(64)).is_err());
        let h = format!("{:x}", Sha256::digest(b"a"));
        assert!(validate_digest(b"a", &h).is_ok());
    }
    #[test]
    fn requires_https_allowlist() {
        let req = json!({"allowedHosts":["firmware.example"]});
        assert!(validate_https("https://firmware.example/api", &req).is_ok());
        assert!(validate_https("http://firmware.example/api", &req).is_err());
        assert!(validate_https("https://evil.example/api", &req).is_err());
        assert!(validate_https("https://firmware.example/api", &json!({})).is_err());
    }
    #[test]
    fn version_and_identity_are_bound() {
        let info = reai_card_sdk::DeviceInfo {
            device_id: "card1".into(),
            version_code: 100,
            ..Default::default()
        };
        let mut req = json!({"module":"main","deviceId":"card1","transportId":"ble1","installedVersionCode":100,"targetVersionCode":101,"targetVersion":"0.1.1"});
        assert!(validate_binding(&info, &req, "ble1").is_ok());
        req["deviceId"] = json!("card2");
        assert!(validate_binding(&info, &req, "ble1").is_err());
        req["deviceId"] = json!("card1");
        req["targetVersionCode"] = json!(100);
        assert!(validate_binding(&info, &req, "ble1").is_err());
    }
}
