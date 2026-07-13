# 4. 表示层与编译合同

## 4.1 固定的表示层

v0.2 使用五个职责分区，其中编译链跨越前三个分区：

```text
Narrative Authority
  NarrativeFactRevision（镜头级输入为 BeatRevision + StoryEvent）
        ↓ Narrative → Directing（人工/导演 Agent，需授权）
Directing Authority
  ShotPlanRevision
        ↓ deterministic compiler
Derived Execution
  GenerationSpecRevision（模型无关）
        ↓ provider adapter
  ProviderRequestSnapshot（Provider 专用）
        ↓ provider gateway
  GenerationAttempt → Candidate AssetVersion
        ↓ analyzers / reviewers
Observation → Decision
```

四种表示名称固定为：

1. `NarrativeFactRevision`
2. `DirectorPlanRevision`（镜头实现类型为 `ShotPlanRevision`）
3. `GenerationSpecRevision`
4. `ProviderRequestSnapshot`

`Prompt IR`、`Canonical Shot`、`Director IR`、`VideoGenerationSpec` 不再作为同级正式实体名。文档或代码若保留这些词，只能是迁移别名，并必须映射到上述四层之一。

## 4.2 NarrativeFactRevision

叙事表示只陈述世界事实和因果，不包含景别、镜头运动、Provider、提示词或模型能力妥协。镜头级最小输入为一个确切 `BeatRevision` 及其 `StoryEvent`。

StoryEvent 建议包含：

- actor / action / object 等语义参与者的确切 Revision 引用；
- 前置条件与状态效果；
- 权威对白或对白引用；
- 情绪/关系变化；
- 因果关联和必须保持的否定事实。

编译器不得从 ShotPlan 的自由文本中反向创造 StoryEvent。发现导演意图要求新事实时，编译失败并返回 `narrative_revision_required`。

## 4.3 DirectorPlanRevision

`ShotPlanRevision` 回答如何呈现：

- 覆盖哪个 Beat Revision 的哪些 StoryEvent；
- 呈现目标、镜头类型和时长范围；
- 相机、构图、调度、表演与声音策略；
- 计划开始/结束状态和镜头内转换；
- 必须出现、禁止出现和参考资产约束。

它是 Directing Authority，不是编译缓存。即使没有任何 Provider 可执行，导演方案仍然有效。Provider 能力不足只能导致编译/路由失败，不能让 Adapter 悄悄削弱导演要求。

`audio_strategy` 只描述媒介生产关系，使用 Provider 中立的 `no_dialogue`、`joint_audio_video`、`authoritative_voice_first`、`separate_dialogue_and_scene_audio` 或 `voice_over`。具体语音/视频服务只在 Router 和 ProviderRequestSnapshot 中出现。只要存在对白，`dialogue_authority` 必须是绑定的 Narrative Revision；联合生成或候选音轨仍只是 Derived Execution 输出及 Observation 对象，不能成为对白权威。

## 4.4 GenerationSpecRevision

Generation Spec 是模型无关、不可变、可重编译的 Derived Execution 记录。建议最小合同：

```json
{
  "generation_spec_id": "gen_ep01_sc03_sh05_video",
  "revision_id": "rev_...",
  "output_kind": "video",
  "source_refs": [],
  "compiler": {
    "compiler_id": "shot_video_compiler",
    "compiler_version": "0.2.0",
    "config_ref": {},
    "template_bundle_hash": "sha256:..."
  },
  "requirements": {
    "duration": {},
    "aspect_ratio": "9:16",
    "semantic_events": [],
    "visual_direction": {},
    "audio": {},
    "continuity": {},
    "hard_constraints": [],
    "soft_preferences": []
  },
  "reference_asset_refs": [],
  "dependency_edges": [],
  "canonical_payload_hash": "sha256:..."
}
```

字段语义：

- `generation_spec_id`：同一逻辑输出意图的稳定 ID，通常由 ShotPlan logical ID + output kind + profile 组成。
- `source_refs`：参与编译的所有 exact Revision/Version；不得出现 head 或 URL 漂移引用。
- `compiler`：编译器实现、版本、配置 Revision 与模板内容哈希。
- `requirements`：能力和内容要求；`hard_constraints` 无法满足时必须失败，`soft_preferences` 才允许记录降级。
- `reference_asset_refs`：精确 AssetVersion 引用，并建立 `reference_asset` 依赖边。
- `canonical_payload_hash`：对规范化 payload 计算，用于确定性校验和去重。

Generation Spec 不包含 Provider 名、私有参数名、临时签名 URL、API Key、Provider operation ID 或原始响应。

## 4.5 ProviderRequestSnapshot

Adapter 把一个 Spec 映射为一个 Provider 请求快照。最小合同包含：

```text
request_snapshot_id
generation_spec_revision_ref
adapter_id / adapter_version
provider_id / endpoint / model_version
capability_snapshot_ref
resolved_parameters
compiled_prompt_segments[]
resolved_reference_manifest[]
request_payload_hash
redacted_payload
encrypted_raw_payload_ref（可选）
created_at
```

规则：

1. `compiled_prompt_segments` 标明来源（StoryEvent、Director field、policy、adapter boilerplate），避免一段不可解释的字符串。
2. 临时 URL 只用于发送；长期快照保存 AssetVersion、对象键和发送时内容哈希。重放时重新签名。
3. 密钥、认证头和个人敏感信息不得进入普通快照或日志。确需保存的原始请求加密、限权并设保留期。
4. Adapter 必须保存能力快照。Provider 后来改变默认值时，历史请求仍可解释。
5. 无法满足 hard constraint 时返回结构化 `unsupported_capability`，不能静默删除参数。
6. 允许对 soft preference 降级，但必须记录 `deviations[]`、原因和预计影响，交由路由/人工决定是否执行。

## 4.6 GenerationAttempt 与 Candidate AssetVersion

一次 Attempt 绑定一个请求快照；实际持久化字段以 `workflow-runtime.schema.json#/$defs/providerAttempt` 为准，至少固定 `provider_request_snapshot_id + provider_request_snapshot_hash`，并同时固定 resolved execution plan 和 Rights snapshot 的 ID/hash，不能内嵌或追随一份可变“当前请求”。领域层的 GenerationAttempt 与运行时 ProviderAttempt 仍是同一实体。它还记录：

- Attempt ID、幂等键和调用序号；
- queued/submitted/provider operation ID/终态时间；
- 计费、延迟、错误类别、重试关系；
- Provider 原始响应快照引用；
- 零到多个输出 AssetVersion 引用。

Attempt 的正式名称、状态和迁移以 [第 6 章 ProviderAttempt 状态机](06_state_machines.md#67-providerattempt领域章-generationattempt状态机) 为唯一合同；领域章的 `GenerationAttempt` 与该 `ProviderAttempt` 是同一实体。`succeeded` 只表示输出已经完成 finalize 和登记，不表示质量通过、人工批准或进入时间线。

Candidate AssetVersion 保存不可变对象键、内容哈希、媒体探测摘要、来源 Attempt、父资产、许可元数据和业务角色。选择候选是 Decision；被 TimelineClip 使用是引用关系；两者都不是 AssetVersion 内的可变 `approval_status`。

## 4.7 TimelineClip 的编译链边界

TimelineClip 不属于 Generation Spec，也不是 Attempt 输出。只有 Timeline Service 可以在新的 TimelineVersion 中创建它：

```text
ReviewDecision / SelectionDecision
        ↓ 允许使用 exact AssetVersion
TimelineVersion
└── TimelineClip(asset_version_ref, in/out, position, transforms)
```

TimelineClip 必须引用 exact AssetVersion。需要更换候选、裁切或调音时创建新 TimelineVersion；除非明确执行媒体渲染，否则不会创建新媒体资产。最终导出又是一个 Derived Execution 过程，输出新的 AssetVersion 和 Release 候选。

## 4.8 编译步骤

### 正式编译器的不变量

`ShotPlanRevision → GenerationSpecRevision` 只有一条正式路径：版本化、无外部生成模型调用的确定性 Compiler。给定完全相同的 exact inputs、Compiler/配置/模板/规范化版本，输出必须逐字节规范化为同一 payload hash。

非确定性模型只能出现在两个边界：

- **上游 proposal**：提出 Narrative 或 Director 草案；草案经 Schema、确定性领域校验和授权接受后，先落为新的权威 Revision，才可交给正式 Compiler；
- **下游 generation**：消费已冻结的 GenerationSpec/ProviderRequest 产生候选资产，并完整记录 Attempt、种子和 Provider 快照。

禁止在正式 Compiler 内调用 LLM “补齐提示词”、推测缺失状态、改写导演意图或根据 Provider 临时输出回填 Spec。若需要此类创作，Compiler 返回结构化缺口，让上游产生 proposal；若只是 Provider 方言映射，则由确定性 Adapter 完成。

### 阶段 A：解析与锁定输入

1. 接收 exact ShotPlanRevision，不接收 logical ID + `latest`。
2. 解析它引用的 Beat/Scene/Episode、计划连续性快照、人物/服装/场景/道具和参考资产 Revision。
3. 验证项目边界、访问权限、撤销状态、Schema 和扩展注册。
4. 生成输入 manifest；在单一一致性快照或可验证的数据库读版本下读取。

### 阶段 B：语义与导演一致性校验

- StoryEvent ID 必须存在于绑定 Beat Revision；
- ShotPlan 不得声明与叙事事实矛盾的硬事实；
- 计划开始、动作、计划结束满足连续性不变量；
- 时长、对白和动作容量满足项目策略；
- 未知值必须显式为 unknown，不能猜成 known；
- 必填扩展必须有对应验证器。

### 阶段 C：规范化 Generation Spec

编译器按稳定字段顺序、明确单位、明确默认值生成 payload。数组只有在业务语义无序时才排序；动作、对白、时间片等有序数组不得重排。数字禁止依赖浮点本地化格式；时间统一使用整数毫秒。

建议采用 RFC 8785 JSON Canonicalization Scheme 或项目固定的等价规范，并将规范名称/版本写入编译记录。内容哈希覆盖所有会影响输出的字段和扩展。

### 阶段 D：记录血缘和 stale 跟踪

为每个实际读取的输入写 DependencyEdge。`impact_paths` 来自编译器读取跟踪；无法可靠跟踪时使用 `/`。Spec Revision、依赖边和 outbox 事件原子提交。

### 阶段 E：路由和 Provider 适配

Router 使用 Spec 要求、能力快照、健康、预算和用户策略选 Provider。路由选择本身保存为决策/运行记录，不写回 ShotPlan。Adapter 只做表示映射，不做叙事创作。

## 4.9 确定性与缓存

对同一组：

```text
exact source refs
+ source content hashes
+ compiler ID/version
+ compiler config Revision
+ template bundle hash
+ canonicalization version
```

编译器必须产生相同的规范化 payload hash。任何非确定性创作调用都必须遵循上节的 proposal 边界，不能藏在正式编译器内。

缓存键使用上述完整输入集合。缓存命中返回既有 GenerationSpecRevision；不能为了制造“新版本”复制相同内容。若相同输入产生不同 hash，标记 `non_deterministic_compiler`，隔离结果并阻止自动生成。

## 4.10 stale 与重编译

- Spec 保存 exact 输入，因此永远可解释；stale 只表示它不再匹配其跟踪策略下的当前期望输入。
- Spec stale 不原地重写；重新编译产生新的 GenerationSpecRevision。
- 旧 ProviderRequestSnapshot 和 Attempt 仍绑定旧 Spec。
- 正在运行的 Attempt 不接受热更新。取消、等待完成或并行创建新 Attempt 由成本策略决定。
- 新 Spec 不自动废弃旧候选；候选选择界面同时显示 source freshness。
- 已进入 Timeline 的旧候选触发 warning/quality gate，不被后台任务静默替换。

## 4.11 写入权限与失败边界

| 产物 | 写入者 | 失败时的权威结果 |
|---|---|---|
| ShotPlanRevision | Director Service/授权用户 | 保存验证错误，不创建半成品 Revision |
| GenerationSpecRevision | Compiler Service | 结构化 compile failure；不伪造 Spec |
| ProviderRequestSnapshot | Provider Gateway/Adapter 经 Request Snapshot Service API | 结构化 mapping failure；不创建 Attempt |
| GenerationAttempt / ProviderAttempt | Provider Gateway 经 Attempt Service API；Orchestrator 只发命令 | 记录真实失败、费用和可重试性 |
| Candidate AssetVersion | Asset Registry | quarantine 或完整性失败；不登记不存在的媒体 |
| TimelineClip | Timeline Service | 整个 TimelineVersion 提交失败或保持旧版本 |

并发边界：

- 同一编译缓存键由数据库唯一约束或 advisory lock 去重；等待者读取获胜结果。
- 同一 Attempt 幂等键只允许一个可产生副作用的 Provider operation。
- Provider 超时但结果未知时状态为 `outcome_unknown` 的错误类别，先查询 operation，不立即重复计费调用。
- Adapter 映射成功而 dispatch 失败时，请求快照可保留，Attempt 记录失败；重试按策略创建新 Attempt 或复用未提交的 operation。
- 编译中任一输入被撤销，提交阶段再次校验 read epoch；不一致则放弃提交并返回 `input_changed_during_compile`。

## 4.12 验收检查

- [ ] 同一输入重复编译得到相同 payload hash，且只登记一个等价 Spec Revision。
- [ ] 更换 Provider 只创建新请求快照/Attempt，不修改 Narrative 或 Directing Authority。
- [ ] 不支持 hard constraint 的 Provider 被拒绝，降级只发生在 soft preference 且有记录。
- [ ] 从提示词任一片段能追到字段来源或 adapter boilerplate。
- [ ] 运行时临时 URL 和密钥不会污染长期快照。
- [ ] Provider 成功不会自动通过 QC、批准连续性或创建 TimelineClip。
- [ ] stale Spec 可按原 exact inputs 重放；重新编译产生新 Revision 并保留旧 Attempt。
- [ ] 输入在编译过程中变化不会产生混合 Revision 的 Spec。
