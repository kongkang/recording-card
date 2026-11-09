//! Project-local extension of SDK 32a1b86. Shares Core's one ordered inbox and
//! command gate; never calls take or opens a second notification subscription.
use super::*;

/// Both deadlines use absolute instants; unrelated notifications never refresh idle.
#[derive(Clone, Debug)]
pub struct KeepTransferOptions {
    pub expected_bytes: u64,
    pub maximum_bytes: u64,
    pub absolute_timeout: Duration,
    pub idle_timeout: Duration,
}
impl KeepTransferOptions {
    pub fn for_size(expected_bytes: u64) -> Self {
        Self {
            expected_bytes,
            maximum_bytes: 128 * 1024 * 1024,
            absolute_timeout: Duration::from_secs(7200),
            idle_timeout: Duration::from_secs(30),
        }
    }
}

/// Counters only; no raw bytes or transcript. Incomplete data stays untrusted.
#[derive(Default, Debug)]
pub struct KeepTransferStats {
    pub pre_start_bytes: u64,
    pub pre_start_packets: u64,
    pub received_packets: u64,
    pub last_packet_bytes: usize,
    pub start_size: Option<u64>,
    pub end_seen: bool,
    /// Before FILE_UPLOAD write, after stale drain. Live/non-fenced snapshot;
    /// connection counters are never reset, including concurrent audio/events.
    pub sdk_begin: Option<SdkNotificationCounters>,
    /// Fixed prefixes captured by the same notification worker that enqueued
    /// these FILE_UPLOAD frames. Not sampled later by the keep receiver.
    pub sdk_start: Option<SdkNotificationCounters>,
    pub sdk_end: Option<SdkNotificationCounters>,
    /// Optional, live/non-fenced cross-layer samples at command begin and when
    /// keep consumes end. None means unavailable/not reached, never measured 0.
    pub transport_begin: Option<Value>,
    pub transport_end: Option<Value>,
}

struct KeepGuard {
    core: Arc<Core>,
    finished: bool,
    active_owned: bool,
}
impl Drop for KeepGuard {
    fn drop(&mut self) {
        if self.active_owned {
            self.core
                .file_transfer_active
                .store(false, Ordering::SeqCst);
        }
        if !self.finished {
            // Preflight can also leave partial commands/replies when cancelled.
            // Poison synchronously; explicit disconnect joins this SAME job.
            self.core.terminal.send_replace(true);
            self.core.source_epoch.fetch_add(1, Ordering::SeqCst);
            let _ = self.core.events.send(DeviceEvent::Disconnected);
            if tokio::runtime::Handle::try_current().is_ok() {
                self.core.begin_disconnect();
            }
        }
    }
}
impl DyjDevice {
    /// Monotonic continuity token, not a firmware generation ID.
    pub fn source_epoch(&self) -> u64 {
        self.core.source_epoch.load(Ordering::SeqCst)
    }
    pub fn is_terminal(&self) -> bool {
        *self.core.terminal.borrow()
    }
    /// Waits on the existing sticky terminal watch, not another NUS subscription.
    pub async fn wait_terminal(&self) {
        let mut terminal = self.core.terminal.subscribe();
        let _ = terminal.wait_for(|closed| *closed).await;
    }

    /// Fresh BASE_INFO >=309 enables keep. Every incomplete outcome invalidates
    /// the stream; source retention relies on the verified >=309 keep protocol.
    pub async fn download_file_preserving_to<W: AsyncWrite + Unpin>(
        &self,
        name: &str,
        writer: &mut W,
        options: KeepTransferOptions,
        cancel: watch::Receiver<bool>,
        progress: impl FnMut(u64, u64),
    ) -> Result<TakenFile> {
        self.download_file_preserving_with_stats_to(
            name,
            writer,
            options,
            cancel,
            progress,
            &mut KeepTransferStats::default(),
        )
        .await
    }

    /// Same safety and ordering as the public keep API; diagnostics do not accept
    /// pre-start data, alter the file size, pad gaps, or acknowledge deletion.
    pub async fn download_file_preserving_with_stats_to<W: AsyncWrite + Unpin>(
        &self,
        name: &str,
        writer: &mut W,
        options: KeepTransferOptions,
        mut cancel: watch::Receiver<bool>,
        mut progress: impl FnMut(u64, u64),
        stats: &mut KeepTransferStats,
    ) -> Result<TakenFile> {
        *stats = KeepTransferStats::default();
        if options.expected_bytes > options.maximum_bytes
            || options.absolute_timeout.is_zero()
            || options.idle_timeout.is_zero()
        {
            return Err(SdkError::InvalidCommand(
                "invalid keep transfer limits".into(),
            ));
        }
        // Capture BEFORE preflight, never absorb a mutation while waiting for a
        // lock or between RECORD_STATUS and FILE_UPLOAD into a fresh baseline.
        let epoch = self.source_epoch();
        let deadline = tokio::time::Instant::now() + options.absolute_timeout;
        let mut idle = tokio::time::Instant::now() + options.idle_timeout;
        let mut terminal = self.core.terminal.subscribe();
        let mut guard = KeepGuard {
            core: self.core.clone(),
            finished: false,
            active_owned: false,
        };
        macro_rules! bounded {
            ($future:expr) => {
                tokio::select! {
                    biased;
                    _ = cancel.wait_for(|cancelled| *cancelled) => return Err(SdkError::InvalidCommand("keep transfer cancelled; source retained".into())),
                    _ = terminal.wait_for(|closed| *closed) => return Err(SdkError::Disconnected),
                    _ = tokio::time::sleep_until(deadline) => return Err(SdkError::Timeout { command: "FILE_UPLOAD absolute".into(), seconds: options.absolute_timeout.as_secs() }),
                    _ = tokio::time::sleep_until(idle) => return Err(SdkError::Timeout { command: "FILE_UPLOAD idle".into(), seconds: options.idle_timeout.as_secs() }),
                    result = $future => result,
                }
            }
        }
        let preflight = async {
            let info = self.device_info().await?;
            if info.version_code < 309 {
                return Err(SdkError::InvalidCommand(
                    "FILE_UPLOAD keep requires verified main firmware >=309".into(),
                ));
            }
            let record = self.record_status().await?;
            if record.is_recording
                || record.realtime_enabled
                || self.core.realtime_active.load(Ordering::SeqCst)
            {
                return Err(SdkError::RealtimeRecordingActive);
            }
            self.require_sd_on_nrf("FILE_UPLOAD").await
        };
        bounded!(timeout(Duration::from_secs(35), preflight)).map_err(|_| {
            SdkError::Timeout {
                command: "KEEP_PREFLIGHT".into(),
                seconds: 35,
            }
        })??;
        idle = tokio::time::Instant::now() + options.idle_timeout;
        let _command = bounded!(self.core.command_gate.lock());
        let mut incoming = bounded!(self.core.incoming.lock());
        discard_stale_inbound(&mut incoming, "FILE_UPLOAD")?;
        if self.is_terminal() {
            return Err(SdkError::Disconnected);
        }
        if self.source_epoch() != epoch {
            return Err(SdkError::Protocol(
                "SD/recording ownership changed during preflight; source retained".into(),
            ));
        }
        stats.sdk_begin = Some(self.sdk_notification_counters());
        stats.transport_begin = self.notification_diagnostics();
        self.core.file_transfer_active.store(true, Ordering::SeqCst);
        guard.active_owned = true;
        bounded!(self.write_command("FILE_UPLOAD", Some(json!({"name": name, "keep": true}))))?;
        idle = tokio::time::Instant::now() + options.idle_timeout;
        let mut started = false;
        let mut written = 0u64;
        let mut result_name = name.to_owned();
        loop {
            if self.source_epoch() != epoch {
                return Err(SdkError::Protocol(
                    "SD/recording ownership changed; source retained".into(),
                ));
            }
            let next = bounded!(incoming.recv()).ok_or(SdkError::Disconnected)?;
            match next {
                Inbound::Disconnected => return Err(SdkError::Disconnected),
                Inbound::Fault(message) => return Err(SdkError::Protocol(message)),
                Inbound::Binary(bytes) if started => {
                    stats.received_packets = stats.received_packets.saturating_add(1);
                    stats.last_packet_bytes = bytes.len();
                    let total = written.checked_add(bytes.len() as u64).ok_or_else(|| {
                        SdkError::InvalidFrame("keep stream size overflow".into())
                    })?;
                    if total > options.expected_bytes || total > options.maximum_bytes {
                        return Err(SdkError::FileLengthMismatch {
                            expected: options.expected_bytes,
                            actual: total,
                        });
                    }
                    bounded!(writer.write_all(&bytes))?;
                    written = total;
                    if !bytes.is_empty() {
                        idle = tokio::time::Instant::now() + options.idle_timeout;
                    }
                    progress(written, options.expected_bytes);
                }
                Inbound::Text(frame, boundary) if frame.command == "FILE_UPLOAD" => {
                    match frame.payload.get("state").and_then(Value::as_str) {
                        Some("start") => stats.sdk_start = boundary.map(|snapshot| *snapshot),
                        Some("end") => {
                            stats.sdk_end = boundary.map(|snapshot| *snapshot);
                            stats.transport_end = self.notification_diagnostics();
                        }
                        _ => {}
                    }
                    ensure_success(&frame.command, &frame.payload)?;
                    match frame.payload.get("state").and_then(Value::as_str) {
                        Some("start") if !started => {
                            let size = required_u64(&frame.payload, "size")?;
                            stats.start_size = Some(size);
                            if size != options.expected_bytes || size > options.maximum_bytes {
                                return Err(SdkError::FileLengthMismatch {
                                    expected: options.expected_bytes,
                                    actual: size,
                                });
                            }
                            started = true;
                            if let Some(name) = frame.payload.get("name").and_then(Value::as_str) {
                                result_name = name.to_owned();
                            }
                            idle = tokio::time::Instant::now() + options.idle_timeout;
                        }
                        Some("end") if started => {
                            stats.end_seen = true;
                            if written != options.expected_bytes {
                                return Err(SdkError::FileLengthMismatch {
                                    expected: options.expected_bytes,
                                    actual: written,
                                });
                            }
                            bounded!(writer.flush())?;
                            if self.source_epoch() != epoch || self.is_terminal() {
                                return Err(SdkError::Disconnected);
                            }
                            guard.finished = true;
                            return Ok(TakenFile {
                                name: result_name,
                                bytes_written: written,
                            });
                        }
                        _ => {
                            return Err(SdkError::InvalidFrame(
                                "invalid/duplicate FILE_UPLOAD start/end".into(),
                            ));
                        }
                    }
                }
                Inbound::Binary(bytes) => {
                    stats.pre_start_bytes =
                        stats.pre_start_bytes.saturating_add(bytes.len() as u64);
                    stats.pre_start_packets = stats.pre_start_packets.saturating_add(1);
                }
                // Unrelated events and pre-start binary never refresh idle.
                _ => {}
            }
        }
    }
}

// Conservative invalidation, including failed write attempts. No wall-clock or
// filename reuse can turn this local continuity token into a remote atomic CAS.
pub(super) fn mutating_command(command: &str) -> bool {
    matches!(
        command,
        "RECORD_START"
            | "RECORD_STOP"
            | "RECORD"
            | "RECORD_MARK"
            | "RECORD_REALTIME_ENABLE"
            | "WIFI_OPEN"
            | "WIFI_CLOSE"
            | "WIFI_OFF"
            | "WIFI_CONNECT"
            | "WIFI_DISCONNECT"
            | "WIFI_AUTOCONNECT"
            | "FILE_DELETE"
            | "FILE_CLEAR"
            | "UPLOAD_FILE"
            | "UPLOAD_ALL"
            | "SYNC"
            | "OTA_WIFI_START"
            | "OTA_START"
            | "REBOOT"
            | "SHUTDOWN"
    )
}
pub(super) fn mutating_frame(frame: &TextFrame) -> bool {
    match frame.command.as_str() {
        "RECORD_STATUS" => {
            frame.payload.get("reason").is_some()
                || frame.payload.get("isRecording").and_then(Value::as_bool) == Some(true)
                || frame
                    .payload
                    .get("realtimeEnabled")
                    .and_then(Value::as_bool)
                    == Some(true)
        }
        "STATE_INFO" => false, // worker tracks ownership edges
        "SYNC_STATUS" => frame.payload.get("state").and_then(Value::as_str) != Some("idle"),
        "WIFI_AP_START" | "UPLOAD_COMPLETE" | "UPLOAD_PROGRESS" => true,
        command => mutating_command(command),
    }
}
