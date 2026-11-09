//! Source-preserving copy and receipt confirmation. Existing firmware has only
//! filename deletion, NOT compare-and-delete. Metadata equality is a diagnostic
//! guard, never authorization for an atomic delete.
use super::*;
use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};
use tokio::io::AsyncWriteExt;

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub(super) struct SourceGeneration {
    pub size: u64,
    pub session: Option<String>,
    pub seq: Option<u32>,
    pub start_at: Option<i64>,
    pub modified_at: Option<i64>,
    pub synced: Option<bool>,
}
#[derive(Clone)]
pub(super) struct DownloadReceipt {
    pub name: String,
    pub device_id: String,
    pub transport_id: String,
    pub path: PathBuf,
    pub bytes: u64,
    pub sha256: String,
    pub ap: bool,
    pub local_epoch: u64,
    pub source_epoch: u64,
    pub generation: Option<SourceGeneration>,
    // A tombstone must only ever be set after an authoritative atomic delete
    // response. Current production code has no such protocol and never sets it.
    pub deleted: bool,
}

pub(super) fn retained(reason: impl Into<String>) -> Error {
    Error::new(
        "source_retained",
        format!("卡端原件保留：{}", reason.into()),
    )
}
pub(super) fn validate_epoch(receipt: &DownloadReceipt, local: u64, source: u64) -> Result<()> {
    if receipt.local_epoch != local || receipt.source_epoch != source {
        return Err(retained(
            "连续AP/SD/录音所有权epoch已变化，旧收据失效，禁止按同名删除",
        ));
    }
    Ok(())
}
fn validate_generation(
    old: &Option<SourceGeneration>,
    current: &Option<SourceGeneration>,
) -> Result<()> {
    if old.is_none() || old != current {
        return Err(retained(
            "远端文件缺失、代际未知或session/seq/时间/长度变化",
        ));
    }
    Ok(())
}
async fn remote_generation(
    d: &DyjDevice,
    name: &str,
    ap: bool,
) -> Result<Option<SourceGeneration>> {
    let remote = name.trim_start_matches('/');
    let mut matches = Vec::new();
    if ap {
        let client = d.access_point_client().await?;
        let mut page = 1;
        loop {
            let result =
                tokio::time::timeout(Duration::from_secs(15), client.list_files(page, 100))
                    .await
                    .map_err(|_| retained("AP元数据读取超时"))??;
            for f in result.files {
                if f.name.trim_start_matches('/') == remote {
                    matches.push(SourceGeneration {
                        size: f.size,
                        session: f.session,
                        seq: f.seq,
                        start_at: f.start_at,
                        modified_at: f.timestamp,
                        synced: f.synced,
                    });
                }
            }
            if page >= result.total_pages {
                break;
            }
            page += 1;
            if page > 1000 {
                return Err(Error::new("protocol", "AP文件页数异常"));
            }
        }
    } else {
        let folder = remote.rsplit_once('/').map(|(folder, _)| folder);
        let files = tokio::time::timeout(Duration::from_secs(35), d.list_files(folder))
            .await
            .map_err(|_| Error::new("timeout", "BLE文件元数据读取超过绝对窗口"))??;
        for f in files {
            let Some(file_name) = f.name.as_deref() else {
                continue;
            };
            let same = file_name.trim_start_matches('/') == remote
                || folder.is_some_and(|folder| format!("{folder}/{file_name}") == remote);
            if same && f.is_dir != Some(1) {
                if let Some(size) = f.size {
                    matches.push(SourceGeneration {
                        size,
                        session: f.session,
                        seq: f.seq,
                        start_at: f.start_at,
                        modified_at: f.created_at,
                        synced: f.synced,
                    });
                }
            }
        }
    }
    if matches.len() > 1 {
        return Err(retained("同名远端条目不唯一"));
    }
    Ok(matches.pop())
}

/// Global cancellation only signals an owned in-flight transfer. It performs no
/// device commands and bypasses the Session lane so it cannot queue behind it.
pub(super) struct TransferCancellation {
    ticket: usize,
    pub cancelled: tokio::sync::watch::Receiver<bool>,
}
pub(super) fn register_transfer(ticket: usize) -> Result<TransferCancellation> {
    let (sender, cancelled) = tokio::sync::watch::channel(false);
    let mut active = state().transfer_cancel.lock().unwrap();
    if active.contains_key(&ticket) {
        return Err(Error::new("busy", "transferTicket已在使用"));
    }
    active.insert(ticket, sender);
    Ok(TransferCancellation { ticket, cancelled })
}
impl Drop for TransferCancellation {
    fn drop(&mut self) {
        state().transfer_cancel.lock().unwrap().remove(&self.ticket);
    }
}
pub(super) fn cancel_transfer(req: &Value) -> Result<Value> {
    let ticket = req
        .get("transferTicket")
        .and_then(Value::as_u64)
        .ok_or_else(|| Error::new("argument", "取消需要transferTicket"))? as usize;
    let active = state().transfer_cancel.lock().unwrap();
    let signalled = active.get(&ticket).is_some_and(|sender| {
        sender.send_replace(true);
        true
    });
    Ok(json!({"cancelSignalled":signalled,"transferTicket":ticket,"sourceDeleted":false}))
}

pub(super) async fn capabilities(session: &Session) -> Result<Value> {
    let code = if let Some(c) = session
        .connection
        .as_ref()
        .filter(|c| !c.device.is_terminal())
    {
        tokio::time::timeout(Duration::from_secs(11), c.device.device_info())
            .await
            .ok()
            .and_then(std::result::Result::ok)
            .map(|info| info.version_code)
    } else {
        None
    };
    Ok(json!({"safeBleDownload":code.is_some_and(|code| code>=309),
        "keepProtocolImplemented":true,"apDownloadPreservesSource":true,
        "confirmDeleteAfterCommit":false,"atomicConditionalDelete":false,
        "minimumKeepFirmwareCode":309,"verifiedMainVersionCode":code,
        "supportsCancellation":true,"cancelOperation":"cancelFileTransfer",
        "reason":"keep copy available only after verified main firmware >=309; filename-only deletion is not generation-safe"}))
}

pub(super) async fn download_preserving(
    session: &mut Session,
    req: &Value,
    cb: Callback,
    ticket: usize,
) -> Result<Value> {
    let registration = register_transfer(ticket)?;
    download_registered(session, req, cb, ticket, registration.cancelled.clone()).await
}
pub(super) async fn download_registered(
    session: &mut Session,
    req: &Value,
    cb: Callback,
    ticket: usize,
    mut cancelled: tokio::sync::watch::Receiver<bool>,
) -> Result<Value> {
    let transfer_cancelled = cancelled.clone();
    let d = session.connection.as_ref().map(|c| c.device.clone());
    let terminal = async {
        if let Some(d) = d {
            d.wait_terminal().await;
        } else {
            std::future::pending::<()>().await;
        }
    };
    tokio::select! {
        biased;
        _ = cancelled.wait_for(|cancelled| *cancelled) =>
            Err(Error::new("cancelled", "保源下载已取消；卡端原件保留，不签发完成收据")),
        _ = terminal => Err(Error::new("disconnected", "保源下载连接已失效；不签发完成收据，卡端保留")),
        result = download_preserving_inner(session, req, cb, ticket, transfer_cancelled) => result,
    }
}
async fn download_preserving_inner(
    session: &mut Session,
    req: &Value,
    cb: Callback,
    ticket: usize,
    mut cancelled: tokio::sync::watch::Receiver<bool>,
) -> Result<Value> {
    let ap = match req
        .get("transport")
        .and_then(Value::as_str)
        .unwrap_or("ble")
    {
        "ble" => false,
        "ap" => true,
        _ => return Err(Error::new("argument", "未知文件传输方式")),
    };
    let name = text(req, "name")?;
    validate_remote(name)?;
    let directory = Path::new(text(req, "directory")?);
    if !directory.is_absolute() {
        return Err(Error::new("argument", "下载目录必须是应用私有绝对路径"));
    }
    let bytes = req
        .get("expectedBytes")
        .and_then(Value::as_u64)
        .ok_or_else(|| Error::new("argument", "保源下载必须提供expectedBytes"))?;
    if bytes > 128 * 1024 * 1024 {
        return Err(Error::new("resource", "文件超过128MiB"));
    }
    let expected_id = text(req, "expectedDeviceId")?.to_owned();
    let d = device(session)?.clone();
    let source_epoch = d.source_epoch();
    let info = required_preflight("BASE_INFO", d.device_info()).await?;
    if info.device_id.is_empty() || info.device_id != expected_id {
        return Err(Error::new("identity", "保源下载目标与当前录音卡身份不一致"));
    }
    if !ap && info.version_code < 309 {
        return Err(Error::new(
            "safeBleUnavailable",
            "真实主控版本未达到309；未发送FILE_UPLOAD，旧固件忽略keep可能删源",
        ));
    }
    let record = required_preflight("RECORD_STATUS", d.record_status()).await?;
    if record.is_recording || record.realtime_enabled {
        return Err(Error::new(
            "busy",
            "请先显式停止录音及实时传输，再下载历史文件",
        ));
    }
    if required_preflight("STATE_INFO", d.state()).await?.wifi_open != ap {
        return Err(Error::new(
            "apUnavailable",
            "SD所有权与所选传输不一致；不会自动切Wi-Fi",
        ));
    }
    let local_epoch = session.receipt_epoch;
    let generation = remote_generation(&d, name, ap).await?;
    if let Some(generation) = &generation {
        if generation.size != bytes {
            return Err(Error::new("integrity", "远端列表长度变化；未开始传输"));
        }
    } else {
        return Err(retained("文件列表未找到目标，未开始传输"));
    }
    if d.source_epoch() != source_epoch {
        return Err(retained("预检期间SD/录音epoch发生变化"));
    }
    if *cancelled.borrow() {
        return Err(Error::new(
            "cancelled",
            "预检期间已取消；未发送文件传输，不删源",
        ));
    }
    if session.receipts.len() >= 2048 {
        return Err(Error::new(
            "resource",
            "下载收据超过连接容量，请结束本次同步后重连",
        ));
    }
    session.next_receipt += 1;
    let id = format!("{}:{}", ticket, session.next_receipt);
    // Create a new directory, never overwrite another recording or another
    // agent's file. All audio/TXT/MRK use the same receipt code, preserving ext.
    tokio::fs::create_dir_all(directory).await?;
    let nonce = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_err(|_| Error::new("io", "本机时间异常"))?
        .as_nanos();
    let owned_dir = directory.join(format!(
        "card-copy-{}-{nonce}-{}",
        std::process::id(),
        session.next_receipt
    ));
    tokio::fs::create_dir(&owned_dir).await?;
    let part = owned_dir.join("download.part");
    let mut writer = tokio::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&part)
        .await?;
    let seconds = req
        .get("absoluteTimeoutSeconds")
        .and_then(Value::as_u64)
        .unwrap_or(7200)
        .clamp(1, 7200);
    let idle_seconds = req
        .get("idleTimeoutSeconds")
        .and_then(Value::as_u64)
        .unwrap_or(30)
        .clamp(1, 60);
    progress(
        cb,
        ticket,
        if ap { "apDownload" } else { "bleKeep" },
        Some(0),
        Some(bytes),
    );
    let transfer: Result<(u64, Option<String>)> = if ap {
        let client = d.access_point_client().await?;
        tokio::select! {
            biased;
            _ = cancelled.wait_for(|cancel| *cancel) => Err(Error::new("cancelled", "保源下载取消；卡端原件保留")),
            result = tokio::time::timeout(Duration::from_secs(seconds), client.download_file_to_bounded(name,&mut writer,bytes,Duration::from_secs(idle_seconds))) => {
                match result { Ok(result) => result.map(|result|(result.bytes_written,result.suggested_name)).map_err(Error::from),
                    Err(_) => Err(Error::new("timeout", "AP保源下载绝对超时；卡端原件保留")) }
            }
        }
    } else {
        let mut options = reai_card_sdk::KeepTransferOptions::for_size(bytes);
        options.absolute_timeout = Duration::from_secs(seconds);
        options.idle_timeout = Duration::from_secs(idle_seconds);
        let mut stats = reai_card_sdk::KeepTransferStats::default();
        d.download_file_preserving_with_stats_to(
            name,
            &mut writer,
            options,
            cancelled.clone(),
            |done, total| progress(cb, ticket, "bleKeep", Some(done), Some(total)),
            &mut stats,
        )
        .await
        .map(|result| (result.bytes_written, Some(result.name)))
        .map_err(|e| {
            if *cancelled.borrow() {
                Error::new("cancelled", "保源下载取消；卡端原件保留，连接需重建")
            } else {
                let mut error = Error::from(e);
                error.message.push_str("；keep下载未删源，卡端原件保留");
                error.message.push_str(&format!("；接收统计 {stats:?}"));
                error
            }
        })
    };
    let (received, device_name) = transfer?; // Failed .part retained, never receipt.
    if received != bytes {
        return Err(Error::new("integrity", "下载长度不符；卡端原件保留"));
    }
    if *cancelled.borrow() {
        return Err(Error::new("cancelled", "下载已取消；不签发收据，不删源"));
    }
    #[cfg(test)]
    test_io_boundary(session, "flush", ticket)?;
    writer.flush().await?;
    #[cfg(test)]
    test_io_boundary(session, "sync", ticket)?;
    writer.sync_all().await?;
    drop(writer);
    let digest = hash_local(&part, bytes).await?;
    let current = remote_generation(&d, name, ap).await?;
    validate_generation(&generation, &current)?;
    if d.source_epoch() != source_epoch || d.is_terminal() {
        return Err(retained("下载期间AP/SD/录音epoch改变；不签发可删收据"));
    }
    let original = name.rsplit('/').next().unwrap();
    let naming = reai_card_sdk::recording_file_name(original, device_name.as_deref());
    let path = owned_dir.join(&naming.file_name);
    #[cfg(test)]
    test_io_boundary(session, "rename", ticket)?;
    tokio::fs::rename(&part, &path).await?;
    // Directory durability follows file sync; supported on host/iOS/Android.
    #[cfg(test)]
    test_io_boundary(session, "directory_sync", ticket)?;
    sync_directory(&owned_dir).await?;
    sync_directory(directory).await?;
    #[cfg(test)]
    test_io_boundary(session, "receipt", ticket)?;
    if *cancelled.borrow() {
        return Err(Error::new(
            "cancelled",
            "本机已落盘但确认期间取消；不签发收据，不删源",
        ));
    }
    if d.source_epoch() != source_epoch || d.is_terminal() {
        return Err(retained("签收期间SD/连接epoch改变；本机已保存，卡端保留"));
    }
    let transport_id = session.connection.as_ref().unwrap().discovered.id.clone();
    session.receipts.insert(
        id.clone(),
        DownloadReceipt {
            name: name.to_owned(),
            device_id: expected_id.clone(),
            transport_id: transport_id.clone(),
            path: path.clone(),
            bytes,
            sha256: digest.clone(),
            ap,
            local_epoch,
            source_epoch,
            generation: generation.clone(),
            deleted: false,
        },
    );
    progress(cb, ticket, "downloaded", Some(bytes), Some(bytes));
    Ok(
        json!({"path":path,"bytes":bytes,"originalName":original,"deviceName":device_name,
        "recordedAt":naming.recorded_at.map(|at|at.to_rfc3339()),"downloadId":id,
        "deviceId":expected_id,"transportId":transport_id,"sha256":digest,
        "sourceDeleted":false,"sourceRetained":true,"sourceEpoch":source_epoch,
        "ownershipEpoch":local_epoch,"remoteGeneration":generation,"atomicConditionalDelete":false}),
    )
}
#[cfg(test)]
fn test_io_boundary(session: &Session, stage: &'static str, ticket: usize) -> Result<()> {
    if session.transfer_io_fault == Some(stage) {
        return Err(std::io::Error::other(format!("controlled {stage} failure")).into());
    }
    if stage == "receipt" && session.transfer_io_fault == Some("cancel_at_receipt") {
        cancel_transfer(&json!({"transferTicket":ticket}))?;
    }
    Ok(())
}
async fn sync_directory(path: &Path) -> Result<()> {
    let directory = tokio::fs::File::open(path).await?;
    directory.sync_all().await?;
    Ok(())
}
async fn required_preflight<T>(
    command: &str,
    query: impl std::future::Future<Output = reai_card_sdk::Result<T>>,
) -> Result<T> {
    tokio::time::timeout(Duration::from_secs(11), query)
        .await
        .map_err(|_| Error::new("timeout", format!("{command} 下载预检超过绝对窗口；未删源")))?
        .map_err(Error::from)
}

pub(super) async fn confirm_delete(session: &mut Session, req: &Value) -> Result<Value> {
    if !flag(req, "repositoryCommitted") {
        return Err(Error::new(
            "confirmation",
            "必须音频/侧车完整校验并入库成功，才可确认删源",
        ));
    }
    let id = text(req, "downloadId")?;
    let receipt = session
        .receipts
        .get(id)
        .ok_or_else(|| Error::new("receipt", "下载收据缺失或连接已变化；禁止删源"))?
        .clone();
    if text(req, "expectedDeviceId")? != receipt.device_id || text(req, "sha256")? != receipt.sha256
    {
        return Err(Error::new("identity", "确认删除与收据身份/hash不一致"));
    }
    // Tombstones, if supported by a future verified conditional-delete protocol,
    // are idempotent. Never re-send by filename or delete a newly reused name.
    if receipt.deleted {
        return Ok(json!({"downloadId":id,"sourceDeleted":true,"alreadyDeleted":true}));
    }
    let path = req
        .get("verifiedPath")
        .and_then(Value::as_str)
        .map(Path::new)
        .unwrap_or(&receipt.path);
    if !path.is_absolute() || hash_local(path, receipt.bytes).await? != receipt.sha256 {
        return Err(Error::new(
            "integrity",
            "本机最终文件校验失败；卡端原件保留",
        ));
    }
    let c = session
        .connection
        .as_ref()
        .ok_or_else(|| Error::new("disconnected", "录音卡未连接"))?;
    let d = &c.device;
    validate_epoch(&receipt, session.receipt_epoch, d.source_epoch())?;
    if d.is_terminal() {
        return Err(retained("下载来源连接已终结"));
    }
    if c.discovered.id != receipt.transport_id
        || d.device_info().await?.device_id != receipt.device_id
    {
        return Err(Error::new("identity", "当前设备不是收据下载来源"));
    }
    let record = d.record_status().await?;
    if record.is_recording || record.realtime_enabled {
        return Err(retained("设备正在录音或实时传输"));
    }
    if d.state().await?.wifi_open != receipt.ap {
        return Err(retained("AP/SD所有权改变"));
    }
    let current = remote_generation(d, &receipt.name, receipt.ap).await?;
    validate_epoch(&receipt, session.receipt_epoch, d.source_epoch())?;
    validate_generation(&receipt.generation, &current)?;
    // LIST+DELETE is TOCTOU, even with session/seq/size timestamps identical.
    // SDK FILE_DELETE may also remove TXT implicitly. No firmware-side CAS nor
    // exclusive immutable lease is exposed, so no destructive command is sent.
    Err(retained("已校验本机入库文件与远端元数据；固件没有可信原子条件删除/不可变租约，不能保证仍是同一代，保留音频与所有侧车"))
}
