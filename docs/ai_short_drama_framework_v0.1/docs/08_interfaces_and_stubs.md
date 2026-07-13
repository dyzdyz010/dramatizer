# 8. Provider 接口与 Stub 规范

## 8.1 能力状态

```typescript
type CapabilityMode =
  | "AUTOMATED"
  | "RULE_BASED"
  | "MANUAL"
  | "UNAVAILABLE";
```

Provider 必须声明能力，而不是在运行中隐式失败。

## 8.2 通用生成任务

```typescript
interface GenerationTask<TSpec> {
  id: string;
  projectId: string;
  taskType: string;
  spec: TSpec;
  idempotencyKey: string;
  priority: number;
  dependencyTaskIds: string[];
  capabilityMode: CapabilityMode;
}

interface GenerationResult {
  status:
    | "completed"
    | "failed"
    | "cancelled"
    | "manual_action_required"
    | "blocked";
  assetIds?: string[];
  providerRunId?: string;
  errorCode?: string;
  reason?: string;
  allowedActions?: string[];
}
```

## 8.3 ModelProvider 与 AgentBackend

```typescript
interface ModelProvider {
  generate<T>(request: ModelRequest, schema: JsonSchema<T>): Promise<T>;
  capabilities(): ModelCapabilities;
}

interface AgentBackend {
  createSession(options: AgentSessionOptions): Promise<string>;
  prompt(sessionId: string, content: AgentContent[]): AsyncIterable<AgentEvent>;
  cancel(sessionId: string): Promise<void>;
}
```

## 8.4 图像与视频

```typescript
interface ImageGenerationProvider {
  generate(spec: ImageGenerationSpec): Promise<AssetRef[]>;
  edit(spec: ImageEditSpec): Promise<AssetRef[]>;
  capabilities(): ImageCapabilities;
}

interface VideoGenerationProvider {
  submit(spec: VideoGenerationSpec): Promise<ProviderJobRef>;
  query(job: ProviderJobRef): Promise<ProviderJobState>;
  cancel(job: ProviderJobRef): Promise<void>;
  capabilities(): VideoCapabilities;
}
```

第一版实现：

- `Seedream50Provider`
- `Seedance20Provider`

## 8.5 视频理解与 CV

```typescript
interface VideoUnderstandingProvider {
  analyze(video: AssetRef, expectation: ShotExpectation): Promise<SemanticVideoReport>;
}

interface ComputerVisionAnalyzer {
  analyze(video: AssetRef, expectation: ShotExpectation): Promise<FrameLevelVisionReport>;
}

interface NarrativeReviewProvider {
  review(input: NarrativeReviewInput): Promise<NarrativeQualityReport>;
}
```

第一版实现：

- `GeminiVideoUnderstandingProvider`
- `OpenCvMediaPipeAnalyzer`
- `ClaudeOpus48Reviewer`
- `GPT56SolReviewer`

## 8.6 音频

```typescript
interface VoiceSynthesisProvider {
  synthesize(spec: VoiceSynthesisSpec): Promise<AudioAssetRef>;
}

interface MusicGenerationProvider {
  generate(spec: MusicCueSpec): Promise<AudioAssetRef[]>;
}

interface SoundEffectSourceProvider {
  generate(spec: SoundEffectSpec): Promise<SoundEffectSourceResult>;
}

interface AudioExtractionProvider {
  extractAudio(video: AssetRef, options: AudioExtractionOptions): Promise<AudioAssetRef>;
}

interface SoundEffectPostProcessor {
  process(audio: AudioAssetRef, spec: SoundEffectProcessingSpec): Promise<AudioAssetRef>;
}
```

第一版实现：

- `GPTSoVitsProvider`
- `SunoMusicProvider`
- `SeedanceDerivedSfxProvider`
- `FfmpegAudioExtractionProvider`
- `FfmpegSoundEffectPostProcessor`
- `ManualAudioUploadProvider`

## 8.7 可选能力接口

```typescript
interface LipSyncProvider {
  sync(video: AssetRef, dialogue: AudioAssetRef, options: LipSyncOptions): Promise<AssetRef>;
}

interface AlignmentProvider {
  align(text: string, audio: AudioAssetRef): Promise<WordTiming[]>;
}

interface SourceSeparationProvider {
  separate(audio: AudioAssetRef, targets: string[]): Promise<AudioAssetRef[]>;
}

interface PerformanceDriveProvider {
  drive(character: AssetRef, performance: AssetRef, options: DriveOptions): Promise<AssetRef>;
}
```

## 8.8 Stub 的正确行为

错误：

```json
{"status": "completed", "assetIds": []}
```

正确：

```json
{
  "status": "manual_action_required",
  "reason": "no_lip_sync_provider_configured",
  "allowedActions": [
    "upload_processed_asset",
    "accept_without_processing",
    "replace_shot"
  ]
}
```

## 8.9 Provider 数据隔离

领域层只允许模型无关字段。Provider 特定请求存储在 `ProviderRequestSnapshot`，不得进入 `Shot`、`Character` 等核心表。

```text
Canonical Shot
→ Generation IR
→ Provider Adapter
→ Provider Request Snapshot
```

## 8.10 幂等和回调

- 每次提交使用 `idempotency_key`；
- 外部回调必须验证签名；
- 同一 Provider Job 回调可重复接收；
- 结果以内容哈希去重；
- Job 状态迁移必须单向且可审计。
