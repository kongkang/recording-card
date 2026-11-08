# QA evidence 契约（不等于生产 DTO）

这些JSON用于集成者导出**实际观测值**后做离线校验。F没有定义/修改生产service接口，不能为了满足模板直接伪造receipt/hash/source。工具通过仅证明证据结构与一部分一致性；OAuth安全性、FFI内存、静音检测质量、真实硬件仍需要对应模块行为测试/真机。fixture文件不能当实际运行证据。

## `qa_audit.py flow MANIFEST`

参考可独立运行文件：`qa/fixtures/flow_evidence.fixture.json`。

| 字段 | v1含义/校验 |
|---|---|
| schema_version | 必须为整数1 |
| evidence_kind | fixture / automated_fake / device；device成功receipt不得是fixture |
| defaults | 生产默认观测：auth=signed_out、events_count=0、mock_enabled=false，不是注入夹具之后的状态 |
| records | `id,start_ms,end_ms,raw_text`；稳定ID且不重复、有效区间、原始转写存在 |
| selected_ids | 合法且去重的记录ID；summary来源必须是其子集 |
| summary | 可为null（空列表/无结果合法）；若存在须非空source_ids；points refs含event_id/start_ms/end_ms，区间在原记录内 |
| auth_attempt | 可选；signed_in必须method=oauth_pkce、pkce_method=S256、state_verified/profile_verified/secure_storage=true；legacy_password signed_out合法 |
| asr | 可选；mode=local；configured=false必须failed并有error，不接受空文succeeded |
| tasks | id去重；state仅queued/running/succeeded/failed/cancelled；progress为null或0..100；failed有可读error |
| receipts | succeeded须由outcome_ref找到origin= gateway/repository/model_gateway/export_file且confirmed=true；Wi-Fi需connected=true，OTA需version_verified=true |
| 危险权限 | operation=ble_take无allow_destructive=true时只能failed/cancelled；device OTA running/succeeded需allow_hardware_write=true（实际执行仍须另行精确授权） |

`start_ms/end_ms`用**该source统一时基**（建议录音内毫秒）。不要将显示HH:mm转成“真实日期”或合并不同source时基。输入records为原始来源，points是其引用范围；跨录音、越界、空来源总结都拒绝。生产没有summary/record时要null/空列表，不注入seed满足这个契约。

授权/receipt值由真实controller捕获，并附对应脱敏trace；schema自身无法证明“confirmed确实来自SDK”。不要把Timer的done赋值导成gateway receipt。no mock/default审计是默认composition root观测，不是fixture facade的一句声明。

## `qa_incremental.py MANIFEST`

参考 `qa/fixtures/incremental_evidence.fixture.json`，ABC→BCD→重复BCD。CLI仅一个manifest，错误exit1，成功保持原evidence_kind。

- `raw_before_sha256/raw_after_sha256`是同一原始文本按UTF-8（或明确一致的原始源字节策略）所得SHA-256 map，前后完全相同；`cloud_writes_raw=false`。参考fixture摘要来自ASCII `QA raw A/B/C/D`，不是实际用户录音。实际运行还需检查写入spy/文件路径，不能只填hash不变。
- `windows[]`含`input_ids,result_ids,source_map`；每个window结果恰为该window原记录集合且无重复，不能带入A到BCD。B/C跨窗口source_map不变，重复BCD不增最终实体。`final_record_ids`是窗口结果并集且无重复。
- 此oracle针对**逐record polish/source实体**幂等，不要求连续LLM文本字面完全一样，不适用于把整个window合成一张summary的DTO；集成适配者应导出记录级实际值，而不是改变生产返回形状。
- `record_intervals`与`silence_stages[]`可选；stage含record_id/start_ms/end_ms/boundary_basis=detected_silence/silence_ms>0，要求source内且顺序不重叠。detector阈值、是否保留静音区间/末尾终止段由D最终规则决定；只导出有静音边界的stage，不伪造末段silence。工具不证明实际音频有静音。
- `views[]`含record_id/raw_source_id/polished_source_id/summary_source_id，三视图必须指向该记录稳定source。
- `manual_summary`：selected_record_ids、used_polished_record_ids须一致；existing_summary_ids和used_existing_summary_ids须一致；used_raw_as_polished=false。existing表示该次请求应参与的已有summary集合，不自动上传全库summary。真实模型请求还需捕获body/ID保证值确实来自polished+已有summary，oracle不发送网络。
- `metadata[]`：record_id合法；emotion/speaker/time均带basis。unknown→value=null；speaker/emotion非空只能inferred且uncertain=true；time非空依据measured/device/asr，不由模型推测。模型可能缺metadata时宁可unknown，不填虚构情绪、真实姓名或时间。

`audit_incremental(data)`返回`evidence_kind,stable_records,meaning`；违规抛 `qa_audit.AuditError`。本补充helper仅Python标准库，不增加生产依赖。

## `qa_audit.py exports MANIFEST [--base DIR]`

字段：schema_version=1、evidence_kind、required_text（已知标题/正文/来源片段）、formats键**恰好**html/markdown/pdf/png/docx，值是相对manifest目录或base目录的实文件路径。所有格式必须非空。PDF调用本地pdftotext解析；DOCX必须有效OOXML，PNG核签名/chunks/CRC/解压。

`generate_qa_specimens.py --output-dir DIR`只生成工具自测样本。样本PNG是16×16色块，无文字，明确 `visual_content=NOT_VERIFIED`；不能用它满足产品图片导出的内容完整性。真实PNG还需视觉验证标题/全文/来源与分页/截断，真实share需系统面板验收。校验工具不含renderer/native share，不向外发文件。

## Source / Baseline / Model

`source --root DIR --strict` 是基于旧风险代码模式的启发式扫描；strict有任何BLOCKER/REVIEW/UNVERIFIED即exit1。source moved/missing是UNVERIFIED，既不算实现失败也不算通过。零findings不是安全证明：集成审查需逐路径检查B命令lane、内存free/finally、A真实OAuth、安全存储等，并增加新函数的行为test。规则不能删除来做绿色；确实不再适用时记录变更来源与人工审查证据。

`baseline --inventory FILE --require-legacy-hash`用于F原样保留检查；后续集成迁移旧fixture可以去掉legacy-hash，但prototype SHA始终严格，旧20名称保留必须人工审查断言未弱化。

`models MANIFEST --base DIR`校验files中的path/size_bytes/sha256，不下载、不配置生产、不会推理。参考清单缺文件应exit1；真正native加载/语言精度/资源占用填NOT_RUN直到实际执行。

## 日志/报告最小要求

记录SHA、工具版本、命令、退出码、时间、evidence_kind、用的夹具/授权范围；实际失败/警告/未跑原因全部保留。禁止token、OAuth code/verifier、server secret、Wi-Fi password和真实用户录音原文进入公共日志/Git。source扫描只打印静态路径/风险ID，不打印代码值；flow/incremental结果不打印raw内容。F的全部输出来自非敏感fixture与测试信息。
