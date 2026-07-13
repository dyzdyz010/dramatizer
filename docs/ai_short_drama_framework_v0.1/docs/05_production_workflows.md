# 5. 生产工作流

## 5.1 故事与剧本流程

```text
创意输入
→ Opus 创建/更新剧集圣经
→ Opus 生成整季主线与人物弧
→ Sonnet 扩写单集
→ Terra 编译 Episode/Scene/Beat/Shot
→ 确定性 Schema 和引用校验
→ Luna 做轻量标签与冲突初筛
→ 人工审核
```

输出不是一份纯文本剧本，而是一组可引用、可版本化的领域实体。

## 5.2 分镜预演流程

```text
Canonical Shot
→ Director IR
→ Seedream 分镜候选
→ 选择角色/场景/服装版本
→ 生成低成本 Storyboard
→ GPT-SoVITS 临时或正式配音
→ FFmpeg 生成 Animatic
→ 审核节奏和镜头缺口
```

在视频生成前完成结构和时长确认，以减少昂贵重试。

## 5.3 关键帧与视频流程

```text
Shot approved for generation
→ Seedream 生成首帧/尾帧/关键帧
→ 人工锁定关键帧
→ Terra 编译 VideoGenerationSpec
→ Seedance 生成 N 个候选
→ 媒体技术 QC
→ Gemini 视频理解
→ CV 分析
→ Opus/Sol 叙事审核
→ 人工选片
```

允许仅重生成单个 Shot 或单个候选，不重新运行整集。

## 5.4 对白与音频策略路由

```yaml
audio_strategy:
  no_dialogue:
    lip_sync: skip
    subtitle: skip

  seedance_native:
    dialogue_authority: model_generated_until_approved
    lip_sync: qc_only
    subtitle: transcribe_and_compare

  gpt_sovits_first:
    dialogue_authority: script_authoritative
    lip_sync: qc_only_or_optional_repair
    subtitle: timeline_or_tts_segment

  hybrid:
    dialogue: gpt_sovits
    ambience_and_foley: seedance_native
    separation: optional

  voice_over:
    lip_sync: skip
    subtitle: timeline_based
```

## 5.5 字幕流程

字幕内容始终以权威台词为准。

优先级：

1. TTS/生成服务返回的时间戳；
2. 一句一音频片段，由时间线直接推导；
3. 标点和静音检测推导短语时间；
4. 高精度 Forced Alignment Provider（Stub）；
5. ASR/Gemini 仅用于发现发音和台词差异，不覆盖权威文本。

## 5.6 口型流程

口型同步是条件节点，不是所有镜头必经节点。

需要处理的典型条件：

- 嘴部清晰可见；
- 最终对白不是生成视频时使用的音频；
- 台词、语速或语言被替换；
- QC 判定音画偏移超过阈值。

不需要处理：

- 旁白；
- 背影/侧后方；
- 道具和环境特写；
- Seedance 已使用最终音频且 QC 通过；
- 原生 Seedance 音频整体被批准。

首版无专用 Provider 时：

```text
LipSyncNode
├── 不需要 → skipped_by_policy
├── 已自然同步并通过 QC → passed
├── 需要但无 Provider → manual_action_required
└── 必须修复且无法人工 → blocked
```

## 5.7 Seedance 派生音效流程

### 生成规范

`SoundEffectSpec` 描述：

- 事件主体和材质；
- 动作力度；
- 录音距离；
- 空间环境；
- 是否需要混响；
- 预期时长；
- 禁止音乐、对白和其他声音。

### 处理链

```text
SeedanceDerivedSfxProvider
→ video source
→ FfmpegAudioExtractionProvider
→ trim / silence removal
→ denoise / normalize / limiter
→ quality review
→ SfxAsset
→ Asset Registry
```

### 循环素材

雨声、风声、机器运转等连续声音需要额外生成无缝循环点和交叉淡化版本。

## 5.8 时间线与后期流程

时间线轨道：

- Video Track；
- Dialogue Track；
- Voice-over Track；
- Ambience Track；
- Foley/SFX Track；
- Music Track；
- Subtitle Track；
- Effect/Overlay Track。

时间线编辑必须非破坏性，只保存引用、入点、出点、变速、音量和效果参数。

最终导出前执行：

- 分辨率、帧率和色彩统一；
- 音轨混合；
- 对白 Ducking；
- 响度标准化；
- 字幕渲染或外挂；
- 平台安全区检查；
- 封面和元数据生成；
- 技术 QC。

## 5.9 失败恢复

每个节点必须幂等。相同 `idempotency_key` 不应重复产生不可控副作用。

失败后可选择：

- retry same provider；
- regenerate with modified IR；
- choose another candidate；
- upload manual result；
- skip by policy；
- block and request decision。
