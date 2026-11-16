# 记录整理提示词与接口 I/O

本文说明 App 里「记录整理」相关云端请求的**提示词来源、输入输出与产品展示落点**。睡前日记 / 做梦管线尚未接通（设置里「日报与做梦」提示词目前仅持久化，无消费方）。

## 总览

| 环节 | 设置页 Tab | Store 键 | 消费方 | 网关 |
| --- | --- | --- | --- | --- |
| 总结生成 | `summary` | `prompts.summary` | `SummaryGenerator` | `POST /api/model-gateway/v1/chat/completions` |
| 口语清洗与分段 | `polish` | `prompts.polish` | `RollingCleanSegmentService` | 同上 |
| 日报与做梦 | `dream` | `prompts.dream` | **尚未接线** | — |

预设风格（内置 + 用户增改）存在 `AgentConfigStore`：选中预设会加载三套提示词；用户预设支持新增 / 改名 / 删除 / 写回。

---

## 1. 总结生成（`summary`）

**代码**：`app/lib/services/ai/summary_generator.dart`

### System

1. 用户在设置里写的 `promptFor('summary')`（角色与整理口径）
2. 已启用 Skills 的规则行（若有）
3. 客户端固定追加的 JSON 契约（用户无需手写）：`title / overview / structure / points / todos / fullText`

### User（输入）

按时间排序的多条记录拼接文本，形如：

```text
[记录id] 标题（时间）
说话人：……
原文转写……
```

### 模型输出 → App 落点

| JSON 字段 | 产品展示 |
| --- | --- |
| `title` | 总结卡标题 / 结果页标题 |
| `overview` | 「概览」Tab |
| `structure` | 「逻辑结构」Tab |
| `points` | 「信息点」Tab（含 `sources` 溯源记录 id） |
| `todos` | 「行动项」Tab |
| `fullText` | 结果页「全文」润色正文 |

失败时如实报错（未登录 / 云端关闭 / 无转写），不编造内容。

---

## 2. 口语清洗与分段（`polish` · 滚动语义整理）

**代码**：`app/lib/services/segment/rolling_clean_segment_service.dart`

这是「记录整理」主路径：端侧 VAD+ASR+声纹之后，按清洗周期把连续说话组分批上行，做语义合并与话题切分。

### System

固定专家指令（丢弃噪音、声纹纠偏、合并自然段、阶段话题命名、忠实 JSON）+ 用户风格偏好：

```text
用户风格偏好：{promptFor('polish')}
```

以及已启用 Skills 规则。

### User（输入 JSON）

```json
{
  "speaker_voiceprint_context": {
    "observed_speakers": ["说话人 1", "说话人 2"],
    "cluster_similarities": [{"a": "说话人 1", "b": "说话人 2", "sim": 0.91}],
    "voiceprint_weak_hints": [{"slot": "说话人 2", "maybe": "张总"}]
  },
  "previous_organized_context": {
    "hasPrevious": true,
    "previousSection": {"title": "...", "brief": "...", "overview": "..."},
    "overlapMode": "paragraphs",
    "tailParagraphs": [{"speaker": "说话人 1", "text": "..."}]
  },
  "utterances": [
    {
      "u": 0,
      "offsetSec": 0,
      "durSec": "2.4",
      "speaker": "说话人 1",
      "spkConf": 0.86,
      "text": "原始 ASR 文本"
    }
  ]
}
```

隐私边界：只上行文本、说话人簇标签、置信度与**簇间标量相似度**，不上传原始声纹向量 / 音频。

### 模型输出 → App 落点

```json
{
  "sections": [
    {
      "continuesPrevious": false,
      "mergesPreviousParagraph": false,
      "title": "6–20 字话题标题",
      "brief": "1–2 句摘要",
      "overview": "2–4 句阶段概述",
      "tags": ["关键词"],
      "paragraphs": [
        {
          "uStart": 0,
          "uEnd": 2,
          "speaker": "说话人 1",
          "text": "合并润色后的自然段"
        }
      ]
    }
  ]
}
```

| 字段 | 产品展示 |
| --- | --- |
| `sections[].title / brief / overview` | Timeline 卡片标题与展开摘要；详情「对话详情」话题段 |
| `paragraphs[].text` | 详情对话流中的整理正文（同说话人连续段已合并） |
| `paragraphs[].speaker` | 说话人标签（可再被声纹命名覆盖） |
| `continuesPrevious` / 重叠上下文 | 跨清洗批次话题续写，避免重复标题碎片 |

顶栏进度文案使用人类时间（如「正在润色 14:20 这段」），**不展示设备文件名**。

触发条件（开发者设置可调）：清洗周期分钟数、≥1 分钟静默、停录强制重洗等。见 Setting › 开发者选项。

---

## 3. 日报与做梦（`dream`）

设置页可编辑并持久化 `prompts.dream`，但 **App 尚无调用方**。规划中的睡前日记 / 做梦漫画 / Skill 养成见 `docs/handoff/handoff-2026-11-13-memory-diary-agent.md`。接通前改此提示词不会改变线上行为。

---

## 4. 与 Timeline「已合并 N 分片」的关系

「已合并 N 分片」是**端侧相邻短切片合并**的 UI 徽标（浅蓝底 `#EEF5FF` + 蓝字 `#0F4C81`），发生在云端清洗之前；合并规则见设计基线（`<30s` 紧邻合并等）。云端 `polish` 负责的是合并后的语义段落与话题切分，不是这个徽标本身。
