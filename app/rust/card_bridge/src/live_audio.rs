//! Live BLE ADPCM is decoded by the SDK continuously. We consume PCM and save
//! bounded, independent WAV chunks. No FILE_UPLOAD/take, no SD handover and no
//! invented timestamps across gaps. Completed WAV + JSON sidecar survive stop.
use super::*;
use reai_card_sdk::PcmChunk;
use tokio::sync::{broadcast, watch};
use std::path::{Path, PathBuf};

pub(crate) struct LiveTask {
    pub id: String,
    pub prior_realtime: bool,
    pub started_recording: bool,
    stop: watch::Sender<bool>,
    join: JoinHandle<Result<Value>>,
}
fn safe_id(value: &str) -> Result<()> {
    if value.len()>80 || !value.bytes().all(|b| b.is_ascii_alphanumeric() || b==b'-' || b==b'_') {
        return Err(Error::new("argument","音频任务ID只能含字母数字、横线、下划线，且不超过80字节"));
    }
    Ok(())
}
pub(crate) async fn start(session: &mut Session, req: &Value) -> Result<Value> {
    if session.live.is_some() { return Err(Error::new("busy","已有实时音频任务，请先停止或恢复其结果")); }
    let id=text(req,"taskId")?.to_owned(); safe_id(&id)?;
    let dir=PathBuf::from(text(req,"directory")?);
    if !dir.is_absolute() { return Err(Error::new("argument","分片目录必须是应用私有绝对路径")); }
    let seconds=req.get("chunkSeconds").and_then(Value::as_u64).unwrap_or(30);
    if !(1..=300).contains(&seconds) { return Err(Error::new("argument","音频分片长度必须是1到300秒")); }
    let d=device(session)?;
    if d.state().await?.wifi_open { return Err(Error::new("busy","Wi-Fi占有SD；先关闭模块再启动实时BLE音频")); }
    let before=d.record_status().await?;
    if !before.is_recording && !flag(req,"startRecordingIfIdle") { return Err(Error::new("notRecording","设备尚未录音；先开始录音或显式startRecordingIfIdle")); }
    tokio::fs::create_dir_all(&dir).await?;
    let manifest=dir.join(format!("{id}.task.json"));
    // create_new reserves ID atomically; never overwrite a previous recording task.
    let mut manifest_file=tokio::fs::OpenOptions::new().create_new(true).write(true).open(&manifest).await?;
    use tokio::io::AsyncWriteExt;
    manifest_file.write_all(json!({"taskId":id,"state":"starting","sampleRate":16000,"channels":1,"chunkSeconds":seconds,"priorRealtime":before.realtime_enabled,"startedRecording":!before.is_recording,"deviceSession":before.session}).to_string().as_bytes()).await?;
    manifest_file.sync_all().await?;
    drop(manifest_file);
    // Subscribe BEFORE enabling transmission to avoid missing the first notification.
    let audio=d.subscribe_audio();
    if !before.realtime_enabled { d.set_realtime_enabled(true).await?; }
    if !before.is_recording {
        if let Err(e)=d.start_recording().await {
            if !before.realtime_enabled { let _=d.set_realtime_enabled(false).await; }
            return Err(e.into());
        }
    }
    let (stop_tx,stop_rx)=watch::channel(false);
    let task_id=id.clone();
    let capacity=(seconds * reai_card_sdk::SAMPLE_RATE_HZ as u64) as usize;
    let join=tokio::spawn(async move {
        let result=write_chunks(audio,stop_rx,&dir,&task_id,capacity).await;
        match &result {
            Ok(stats) => event(json!({"kind":"audioCaptureStopped","taskId":task_id,"data":stats})),
            Err(e) => event(json!({"kind":"audioCaptureFailed","taskId":task_id,"error":e.message,"code":e.code})),
        }
        result
    });
    session.live=Some(LiveTask { id:id.clone(),prior_realtime:before.realtime_enabled,started_recording:!before.is_recording,stop:stop_tx,join });
    Ok(json!({"taskId":id,"running":true,"sampleRate":16000,"channels":1,"chunkSeconds":seconds,"startedRecording":!before.is_recording,"manifestPath":manifest}))
}
pub(crate) async fn stop(session: &mut Session, req: &Value) -> Result<Value> {
    let id=text(req,"taskId")?;
    if session.live.as_ref().is_none_or(|t|t.id != id) { return Err(Error::new("notFound","实时音频任务ID不匹配")); }
    let live=session.live.take().unwrap();
    let stop_recording=flag(req,"stopOwnedRecording") && live.started_recording;
    let prior=live.prior_realtime;
    let stats=stop_writer(live).await;
    if let Some(c)=&session.connection {
        if stop_recording { c.device.stop_recording().await?; }
        c.device.set_realtime_enabled(prior).await?;
    }
    stats
}
pub(crate) async fn cleanup_live(session: &mut Session) {
    if let Some(live)=session.live.take() {
        let prior=live.prior_realtime;
        let id=live.id.clone();
        if let Err(e)=stop_writer(live).await { event(json!({"kind":"audioCaptureFailed","taskId":id,"error":e.message})); }
        if let Some(c)=&session.connection { let _=tokio::time::timeout(Duration::from_secs(5),c.device.set_realtime_enabled(prior)).await; }
        // Disconnect does not stop someone else's SD recording or delete source.
    }
}
async fn stop_writer(mut task: LiveTask) -> Result<Value> {
    let _=task.stop.send(true);
    match tokio::time::timeout(Duration::from_secs(20),&mut task.join).await {
        Ok(result) => result.map_err(|_|Error::new("io","音频分片写入任务异常停止"))?,
        Err(_) => { task.join.abort(); Err(Error::new("timeout","音频分片落盘超时；未完成.part保留待恢复，不能当完整录音")) }
    }
}
pub(crate) fn status(session: &Session) -> Result<Value> {
    let t=session.live.as_ref().ok_or_else(||Error::new("notFound","没有实时音频任务"))?;
    Ok(json!({"taskId":t.id,"running":!t.join.is_finished(),"startedRecording":t.started_recording}))
}

struct ChunkWriter<'a> {
    dir: &'a Path,
    id: &'a str,
    capacity: usize,
    buffer: Vec<i16>,
    index: u64,
    received_offset: u64,
    discontinuous: bool,
    dropped_chunks: u64,
}
impl ChunkWriter<'_> {
    async fn flush(&mut self, is_final: bool, interrupted: bool) -> Result<()> {
        if self.buffer.is_empty() { return Ok(()); }
        self.index+=1;
        let stem=format!("{}-{:06}",self.id,self.index);
        let path=self.dir.join(format!("{stem}.wav"));
        let part=self.dir.join(format!("{stem}.wav.part"));
        // No deletion/overwrite: task ID was uniquely reserved, each index is unique.
        let mut file=tokio::fs::OpenOptions::new().write(true).create_new(true).open(&part).await?;
        use tokio::io::AsyncWriteExt;
        file.write_all(&reai_card_sdk::wav_bytes(&self.buffer,16000)).await?;
        file.sync_all().await?; drop(file);
        tokio::fs::rename(&part,&path).await?;
        let data=json!({"kind":"audioChunk","taskId":self.id,"index":self.index,"path":path,"samples":self.buffer.len(),"sampleRate":16000,"channels":1,"receivedSampleOffset":self.received_offset,"discontinuous":self.discontinuous,"droppedChunks":self.dropped_chunks,"isFinal":is_final,"interrupted":interrupted});
        tokio::fs::write(self.dir.join(format!("{stem}.json")),data.to_string()).await?;
        event(data);
        self.received_offset+=self.buffer.len() as u64;
        self.buffer.clear(); self.discontinuous=false; self.dropped_chunks=0;
        Ok(())
    }
    async fn push(&mut self, chunk: PcmChunk) -> Result<()> {
        if chunk.sample_rate!=16000 || chunk.channels!=1 { return Err(Error::new("protocol","实时PCM格式不匹配16kHz单声道")); }
        if chunk.discontinuous {
            self.flush(false,true).await?; self.discontinuous=true;
        }
        let mut offset=0;
        while offset<chunk.samples.len() {
            let count=(self.capacity-self.buffer.len()).min(chunk.samples.len()-offset);
            self.buffer.extend_from_slice(&chunk.samples[offset..offset+count]); offset+=count;
            if self.buffer.len()==self.capacity { self.flush(false,false).await?; }
        }
        Ok(())
    }
}
async fn write_chunks(mut rx: broadcast::Receiver<PcmChunk>, mut stop: watch::Receiver<bool>, dir: &Path,id: &str,capacity: usize) -> Result<Value> {
    let mut writer=ChunkWriter {dir,id,capacity,buffer:Vec::with_capacity(capacity),index:0,received_offset:0,discontinuous:false,dropped_chunks:0};
    let mut interrupted=false;
    let mut dropped_total=0u64;
    let idle=tokio::time::sleep(Duration::from_secs(30));
    tokio::pin!(idle);
    loop {
        tokio::select! {
            biased;
            changed=stop.changed() => {
                if changed.is_err() || *stop.borrow() { break; }
            }
            _=&mut idle => {
                interrupted=true;
                event(json!({"kind":"audioGap","taskId":id,"reason":"no_pcm_for_30_seconds","durationUnknown":true}));
                break;
            }
            received=rx.recv() => match received {
                Ok(chunk) => {
                    idle.as_mut().reset(tokio::time::Instant::now()+Duration::from_secs(30));
                    writer.push(chunk).await?;
                }
                Err(broadcast::error::RecvError::Lagged(n)) => {
                    writer.flush(false,true).await?;
                    writer.discontinuous=true; writer.dropped_chunks+=n; dropped_total+=n;
                    event(json!({"kind":"audioGap","taskId":id,"droppedChunks":n,"durationUnknown":true}));
                }
                Err(broadcast::error::RecvError::Closed) => { interrupted=true; break; }
            }
        }
    }
    writer.flush(true,interrupted).await?;
    let stats=json!({"taskId":id,"chunks":writer.index,"receivedSamples":writer.received_offset,"droppedChunks":dropped_total,"interrupted":interrupted,"state":if interrupted {"interrupted"} else {"stopped"}});
    let part=dir.join(format!("{id}.task.json.part"));
    tokio::fs::write(&part,stats.to_string()).await?;
    tokio::fs::rename(part,dir.join(format!("{id}.task.json"))).await?;
    Ok(stats)
}
#[cfg(test)]
mod tests {
    use super::*;
    #[tokio::test] async fn saves_bounded_wav_chunks_and_final_partial() {
        let dir=std::env::temp_dir().join(format!("card-live-test-{}",std::process::id())); tokio::fs::create_dir_all(&dir).await.unwrap();
        let mut w=ChunkWriter{dir:&dir,id:"unit",capacity:4,buffer:Vec::new(),index:0,received_offset:0,discontinuous:false,dropped_chunks:0};
        w.push(PcmChunk{samples:vec![0,1,2,3,4,5],sample_rate:16000,channels:1,discontinuous:false}).await.unwrap();
        w.flush(true,false).await.unwrap();
        assert_eq!(w.index,2); assert_eq!(w.received_offset,6);
        let first=tokio::fs::read(dir.join("unit-000001.wav")).await.unwrap(); assert_eq!(&first[..4],b"RIFF"); assert_eq!(first.len(),44+4*2);
        let meta:Value=serde_json::from_slice(&tokio::fs::read(dir.join("unit-000002.json")).await.unwrap()).unwrap(); assert_eq!(meta["isFinal"],true); assert_eq!(meta["samples"],2);
        tokio::fs::remove_dir_all(dir).await.unwrap();
    }
    #[test] fn rejects_path_in_task_id() { assert!(safe_id("../rec").is_err()); assert!(safe_id("rec_123").is_ok()); }
    #[tokio::test] async fn never_merges_pcm_across_discontinuity() {
        let dir=std::env::temp_dir().join(format!("card-live-gap-test-{}",std::process::id())); tokio::fs::create_dir_all(&dir).await.unwrap();
        let mut w=ChunkWriter{dir:&dir,id:"gap",capacity:16,buffer:Vec::new(),index:0,received_offset:0,discontinuous:false,dropped_chunks:0};
        w.push(PcmChunk{samples:vec![1,2],sample_rate:16000,channels:1,discontinuous:false}).await.unwrap();
        w.push(PcmChunk{samples:vec![3,4],sample_rate:16000,channels:1,discontinuous:true}).await.unwrap();
        w.flush(true,false).await.unwrap();
        assert_eq!(w.index,2);
        let meta:Value=serde_json::from_slice(&tokio::fs::read(dir.join("gap-000002.json")).await.unwrap()).unwrap();
        assert_eq!(meta["discontinuous"],true); assert_eq!(meta["receivedSampleOffset"],2);
        tokio::fs::remove_dir_all(dir).await.unwrap();
    }
}
