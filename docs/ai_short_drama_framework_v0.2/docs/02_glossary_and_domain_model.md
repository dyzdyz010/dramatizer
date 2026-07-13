# 2. 术语表与领域模型 v0.2

## 2.1 本章的合同地位

本章定义跨服务共享的领域语言和边界。字段级交换格式以 `schemas/` 为准；当文字与 Schema 冲突时，发布前必须修正冲突，不能由实现自行猜测。

v0.2 将 v0.1 中职责过重的 `Shot` 拆开。一个“镜头”从叙事到成片不再是一行不断变状态的记录，而是一条由明确引用连接的对象链：

```text
BeatRevision / StoryEvent
        ↓ 覆盖
ShotPlan / ShotPlanRevision
        ↓ 编译
GenerationSpecRevision
        ↓ 适配并执行
GenerationAttempt
        ↓ 产生
Candidate AssetVersion
        ↓ 审核后可被精确引用
TimelineClip
```

## 2.2 五个职责分区及其权威性

| 数据分区 | 回答的问题 | 例子 | 能否直接改写叙事事实 |
|---|---|---|---|
| Narrative Authority | 故事世界中发生什么 | `BeatRevision`、`StoryEvent`、权威对白和人物/道具 Revision | 只有叙事写命令可以；始终新增 Revision |
| Directing Authority | 应如何向观众呈现已确定的事实 | `ShotPlanRevision`、计划连续性快照与转换 | 不能；只能精确引用叙事 Revision |
| Derived Execution | 如何把锁定输入编译并交给执行系统 | `GenerationSpecRevision`、`ProviderRequestSnapshot`、`GenerationAttempt` | 不能；输入变化只会令其 stale 或触发新执行 |
| Observation | 输出中检测到了什么 | `DetectedObservation`、媒体/CV/多模态证据 | 不能；观察可以是错误或不完整的 |
| Decision | 谁基于哪些输入作了何种裁决 | `ContinuityApproval`、`ReviewDecision`、候选选择 | 不能直接改写；可授权创建批准快照或发起新 Narrative/Directing Revision |

前两个分区都是创作权威数据，但权限和语义不同，不能合并成一个可互写的“Canonical”对象。禁止把模型输出、提示词、Provider 响应、CV 标签或“当前最佳候选”存入任何权威字段。接受生成偏差是一项新决策；若改变剧情事实，还必须经 Narrative Authority 创建新的叙事 Revision。

## 2.3 核心术语

### NarrativeFactRevision

权威叙事 Revision 的统称。v0.2 的镜头链以 `BeatRevision` 为最小叙事输入；人物、场景、道具、对白等也采用相同的 logical entity + immutable revision 规则。

### BeatRevision

一个逻辑 `Beat` 的不可变版本，描述一次信息、行动或情绪状态变化。它包含一个或多个 `StoryEvent`。修改任何事件内容、参与者、因果或权威台词，都创建新 `BeatRevision`。

### StoryEvent

`BeatRevision` 内的权威叙事值对象，描述“谁对什么做了什么，以及状态如何改变”。它有在该逻辑 Beat 范围内稳定的 `story_event_id`，但不拥有独立 head pointer；事件的确切版本由 `(beat_revision_id, story_event_id)` 唯一确定。

同一 `story_event_id` 可在后续 Beat Revision 中延续，以便显示差异。删除事件表示新 Beat Revision 不再包含它；旧 Revision 中的事件仍可重放。

### ShotPlan

一个逻辑导演方案的身份和 Revision 流。它不包含视频文件，不表示生成运行，也不等于时间线片段。一个 Beat Revision 可以由多个 ShotPlan 覆盖，一个 ShotPlan Revision 也可以覆盖同一 Beat Revision 中的多个 StoryEvent。

### ShotPlanRevision

权威、不可变的导演表达：呈现目标、景别、机位、运动、表演、调度、时长范围、声音策略、约束以及计划连续性绑定。它精确引用一个 Beat Revision 及其中的 StoryEvent ID，不复制或发明新的叙事事实。

同一 ShotPlan 可以有多个 Revision；同一 Beat Revision 也可以有多个并列 ShotPlan（例如 A/B 导演方案）。“当前采用哪个”由 head/选择决策表达，不能靠覆盖旧记录表达。

### GenerationSpecRevision

模型无关的不可变派生规范。它把一个确定的 ShotPlan Revision、叙事 Revision、连续性快照、参考资产版本和编译器配置归一化为生成能力要求。它可以表达图像、视频、语音或声音生成要求，但不包含 Provider 私有参数。

### ProviderRequestSnapshot

Provider Adapter 产生的不可变执行快照，包含 Provider、模型/端点版本、最终请求参数、编译后提示词、引用资源解析结果、请求哈希和安全脱敏后的原始响应关联。它是重放与审计材料，不是权威创作数据。

### GenerationAttempt

一次实际的外部或本地 Provider 调用记录。一次 Attempt 只绑定一个 `GenerationSpecRevision` 和一个 `ProviderRequestSnapshot`。Provider 级重试若可能产生新的计费、随机输出或副作用，必须创建新的 Attempt；仅网络读取重试可留在同一 Attempt 的 transport 日志中。

Attempt 的终态不代表质量批准。重复回调通过 Provider operation ID 与幂等键合并；不得因此创建重复资产。

### Candidate AssetVersion

一次成功 Attempt 产生或人工导入的不可变媒体版本。`candidate` 是它在选择流程中的角色，不是字节状态。候选即使 QC 失败也保留，以保证证据和成本可追溯。审核通过产生选择/批准决策，不修改文件内容或内容哈希。

### TimelineClip

`TimelineVersion` 内的非破坏性值对象，精确引用某个 `AssetVersion`，并保存入点、出点、轨道、时间位置、变速、音量和效果参数。它不是 ShotPlan 的状态，也不会拥有生成数据。一个 AssetVersion 可被零到多个 TimelineClip 使用；一个 ShotPlan 可无片段、一个片段或多个片段。

### ContinuitySnapshot / StateTransition

`ContinuitySnapshot` 是某一镜头边界上的不可变状态断言集合；`StateTransition` 是镜头内计划动作及其前后状态。计划开始、计划结束与批准结束是不同快照，不使用同一个可变 JSON 字段。

### DetectedObservation / ContinuityApproval / ContinuityEdge

- `DetectedObservation`：针对具体 Candidate AssetVersion 的有来源、有置信度、有时间范围的观察。
- `ContinuityApproval`：人工或已授权确定性策略基于计划和观察作出的决策，并在接受时指向一个新的 `approved_end` 快照。
- `ContinuityEdge`：明确连接上游批准结束快照与下游计划开始快照，并给出连续性轨道、顺序和跳接语义。

## 2.4 组合树不等于 DDD 聚合

以下结构只用于创作导航和组成关系：

```text
Project
└── SeriesBible
    └── Season
        └── Episode
            └── Scene
                └── Beat
                    └── proposed ShotPlan positions
```

它不是一棵需要单事务保存的对象树。尤其不能为了改一个镜头而锁住或重写整个 Episode。

建议的 DDD 聚合边界如下：

| 聚合 | 聚合根 | 聚合内原子不变量 | 跨聚合连接方式 |
|---|---|---|---|
| Beat | `Beat` | Revision 序号、父 Revision、StoryEvent ID 在单 Revision 内唯一 | 精确 Revision 引用、领域事件 |
| ShotPlan | `ShotPlan` | logical ID、head CAS、Revision 血缘 | 精确引用 Beat/Scene/Episode Revision |
| GenerationSpec | `GenerationSpec` | 编译输入集合和内容哈希不可变 | DependencyEdge |
| GenerationAttempt | `GenerationAttempt` | 幂等键、Provider operation 去重、单向运行状态 | 精确引用请求快照与输出资产 |
| Asset | `Asset` | AssetVersion 内容哈希和血缘不可变 | AssetVersion 精确引用 |
| Continuity | 连续性记录各自的 logical owner | 快照/观察/批准不可变，批准权限 | 显式 ContinuityEdge |
| Timeline | `Timeline` | TimelineVersion 内轨道与片段约束 | TimelineClip 精确引用 AssetVersion |

跨聚合更新使用同库事务中的 outbox 或等价可靠事件；不要求分布式事务。事件重复投递必须幂等。

## 2.5 主要基数

```text
Beat 1 ── 1..* BeatRevision
BeatRevision 1 ── 1..* StoryEvent
BeatRevision 1 ── 0..* ShotPlanRevision（通过精确引用）
ShotPlan 1 ── 1..* ShotPlanRevision
ShotPlanRevision 1 ── 0..* GenerationSpecRevision
GenerationSpecRevision 1 ── 0..* GenerationAttempt
GenerationAttempt 1 ── 0..* Candidate AssetVersion
Asset 1 ── 1..* AssetVersion
AssetVersion 1 ── 0..* TimelineClip
Timeline 1 ── 1..* TimelineVersion
TimelineVersion 1 ── 0..* TimelineClip
ShotPlanRevision 1 ── 1 planned-start Snapshot
ShotPlanRevision 1 ── 1 planned-end Snapshot
ShotPlanRevision 1 ── 0..* DetectedObservation
ShotPlanRevision 1 ── 0..* ContinuityApproval
```

“1 个 Attempt 产生 0..* 候选”允许 Provider 一次返回多个输出；每个输出仍是独立 AssetVersion。一个失败 Attempt 不产生伪造占位资产。

## 2.6 写入权限

| 数据 | 唯一允许的写入入口 | 禁止行为 |
|---|---|---|
| BeatRevision / StoryEvent | Narrative Service 的授权命令或人工编辑命令 | Provider、QC、编译器直接写 |
| ShotPlanRevision | Director Service 的授权命令或人工导演编辑 | 生成回调修改导演意图 |
| GenerationSpecRevision | 版本化 Compiler | 人工手改派生字段后冒充可重放结果 |
| ProviderRequestSnapshot | Provider Gateway/Adapter 经 Request Snapshot Service API | UI 用“最后一次请求”覆盖历史 |
| GenerationAttempt / ProviderAttempt | Provider Gateway 经 Attempt Service API；Generation Orchestrator 只提交创建、取消、重生成命令 | Orchestrator 或 QC 直接改 Attempt 行/运行终态 |
| AssetVersion | Asset Registry | 覆盖对象键对应的字节或哈希 |
| DetectedObservation | QC/分析 Worker 或人工标注入口 | 自动升级为权威事实 |
| ContinuityApproval | Review Service；人工审核者、确定性规则、已审计批量策略只作为获授权 actor 提交决策命令 | actor 或未授权 LLM 直接写 Approval repository |
| TimelineVersion / Clip | Timeline Service | 通过“shot included”修改 ShotPlan 状态 |

所有写命令记录 actor、时间、输入 Revision、幂等键和审计关联。服务账号权限按数据分区最小化。

## 2.7 核心不变量

1. logical ID 在实体生命周期内稳定；Revision 写入后不可变。
2. 任意持久化引用若用于重放、生成、审核或时间线，必须指向确切 Revision/Version，禁止 `latest`。
3. head pointer 是独立可变记录；移动 head 不修改旧 Revision。
4. StoryEvent 的语义只由其所属 Beat Revision 决定；ShotPlan 不得偷偷改变事件事实。
5. GenerationSpec 必须可追溯到完整、固定的输入集合、编译器版本和配置哈希。
6. Attempt 成功仅说明取得输出，不表示 QC 或人工批准。
7. 检测结果永远属于观察分区；只有显式决策能形成批准状态。
8. TimelineClip 必须引用不可变 AssetVersion，不能引用逻辑 Asset 的 head。
9. 删除采用 tombstone/revocation；已被审计链引用的 Revision、Attempt、AssetVersion、Observation 和 Decision 不物理删除。
10. 核心 Schema 顶层关闭未知字段；扩展只能放入 `extensions[]`，并提供类型、Schema ID 和版本。
11. ShotPlan 的 `minimum_ms <= preferred_ms <= maximum_ms`；`dialogue_event_ids` 必须是其 `composition.story_event_ids` 的子集，并全部存在于绑定 Beat Revision。
12. Schema 无法表达的跨记录类型、唯一性、排序和引用闭包约束由同版本确定性领域验证器执行，不能只靠 JSON Schema 宣称有效。

## 2.8 失败与并发边界

- 两位编辑从同一 head 创建 Revision 是合法分支；只有 head 移动使用 compare-and-swap。失败方保留其 Revision，并选择重基、合并或建立另一 stream。
- `revision_number` 只用于显示和单 logical ID 内排序，不是锁，也不要求全局连续。
- 生成回调、队列投递和 outbox 消费均按至少一次处理设计；消费者必须根据幂等键、Attempt ID、Provider operation ID 和内容哈希去重。
- 对象存储成功、数据库提交失败时，媒体先进入 quarantine；由补偿任务登记或清理。数据库成功、对象缺失时标记完整性失败，不伪造成功。
- 派生产物 stale 不等于删除或不可重放。正在运行的 Attempt 继续绑定原 Spec；是否取消由策略决定，新输入不能悄悄注入旧 Attempt。
- Timeline 发布与候选审批分别提交；发布服务必须在提交时再次验证所有精确引用、授权和质量门。

## 2.9 验收检查

- [ ] 能从任一 TimelineClip 追到 AssetVersion、Attempt、请求快照、GenerationSpec、ShotPlanRevision 和 BeatRevision。
- [ ] 修改 Beat 后只新增 Revision，并能列出受影响但未被覆盖的 ShotPlan/Spec。
- [ ] 两个导演方案可同时覆盖同一 StoryEvent，且互不覆盖 head。
- [ ] Provider 重复回调不会生成重复 AssetVersion。
- [ ] QC 失败的候选仍可审计，但不会自动成为批准资产或 TimelineClip。
- [ ] `unknown`、`not_present` 和未观察三种情况在连续性数据中可区分。
- [ ] 所有扩展都有可解析的 schema_id；未知顶层字段被拒绝。
- [ ] 组合树的局部编辑无需整棵 Episode 原子写入。
