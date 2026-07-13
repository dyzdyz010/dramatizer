# 1. 范围、原则与系统边界

## 1.1 产品目标

系统是面向连续剧式内容的 AI 原生生产操作系统，目标不是消灭导演、编剧和审核，而是让每次创作决定、生成调用、候选资产、质量证据和人工裁决都可定位、可重放、可替换和可恢复。

首个可验收闭环为：

```text
Project
→ Narrative Revision
→ Director Plan Revision
→ Generation Spec Revision
→ Provider Attempt
→ Candidate AssetVersion
→ Quality Evidence
→ Review Decision
→ TimelineVersion
→ ReleaseManifest
```

## 1.2 MVP 边界

### 范围内

- 9:16 中文连续短剧，单集 60–120 秒、10–30 个镜头计划；
- 剧集圣经、人物、地点、道具、服装、对白和 StoryEvent 的版本化管理；
- 一个 StoryEvent 对应零个或多个导演镜头方案；
- 分镜、关键帧、视频、对白、音乐、环境声和音效候选；
- 单 Shot 独立重生成、候选比较、局部修复和人工上传；
- 技术、语义、CV、叙事四层质量证据；
- 非破坏性多轨时间线、字幕、混音和导出；
- 完整血缘、成本、授权、审计和失败恢复。

### 首版非目标

- 无人工监督的一键发布；
- 完整专业 NLE 的全部功能；
- 所有镜头强制口型修复或逐字对齐；
- 跨 Provider 自动竞价市场；
- 对所有视觉风格一次性建立通用 CV 阈值；
- 在同一事务中实现数据库与对象存储的分布式强一致。

## 1.3 五类数据职责与权威

系统不得把“唯一事实源”误解为所有数据只有一个表。不同事实由不同权威对象负责：

| 分区 | 例子 | 是否权威 | 写入方式 |
|---|---|---:|---|
| Narrative Authority | StoryEventRevision、DialogueRevision、角色/道具 Revision | 是 | 人工命令或经批准的 ChangeProposal |
| Directing Authority | DirectorPlanRevision、ShotPlanRevision、AudioIntent | 是 | 导演编辑或经批准的提案 |
| Derived Execution | GenerationSpecRevision、ProviderRequestSnapshot | 否 | 编译器和 Adapter 生成 |
| Observation | AssetVersion、DetectedObservation、QualityEvidence | 对产物和检测记录权威，但不是叙事权威 | Provider、Worker、Analyzer 写入 |
| Decision | ReviewDecision、ContinuityApproval、Waiver、ReleaseApproval | 对批准行为权威 | 获授权的人工或确定性规则 |

同一个对象可以是真实存在的生产记录，但不因此成为故事世界中的权威事实。例如 ProviderRequestSnapshot 是调用审计的权威记录，却不是叙事权威。

## 1.4 关键设计原则

### 原则 A：逻辑身份与不可变 Revision 分离

可编辑概念拥有稳定 logical ID；每次有效修改创建新 revision ID。生产、审核和发布固定引用 revision ID。`head_revision_id` 只用于编辑导航，不能进入可重放执行输入。

### 原则 B：叙事事实与导演方案分离

StoryEventRevision 描述发生了什么；DirectorPlanRevision 描述如何呈现；ShotPlanRevision 是导演方案中的最小镜头计划。一个 StoryEvent 可以被多个镜头覆盖，一个镜头也可以覆盖多个 StoryEvent。

### 原则 C：正式编译确定性，非确定性生成可追溯

正式 `ShotPlanRevision → GenerationSpecRevision` 编译器必须是确定性程序：固定输入 Revision 闭包、编译器版本与策略版本必定得到相同的规范化输出和 hash。LLM 只能参与上游 Director proposal（经审核后形成新的 Directing Revision）或下游 Provider generation，不能置于正式编译器内部。非确定性生成不承诺位级复现，但必须固定请求快照、模型/参数/seed、输出 hash，并保证验证和失败处理可重放。

### 原则 D：观察、建议、批准分离

Analyzer 写 QualityEvidence；Decision Engine 写 AutomatedQualityDecision；只有 ReviewDecision 或明确获授权的规则能批准资产、接受偏差或创建权威变更提案。

### 原则 E：至少一次执行与幂等副作用

队列、回调和 Worker 允许重复投递。每个副作用必须通过作用域明确的幂等键、唯一约束、Inbox/Outbox 或内容 hash 收敛。

### 原则 F：先门禁，后昂贵副作用

Provider 提交前依次完成输入 Revision 固定、stale 检查、只读 Capability/Health/Quota 候选预筛、针对候选的 Rights Gate、最终 Capability/Route Resolution、Budget Reservation 和幂等提交记录。预筛不是授权，不能创建可执行 plan；任何门失败都不得先产生不可控外部费用。

## 1.5 逻辑模块与物理部署

MVP 采用模块化单体控制平面，而不是提前拆微服务：

```text
Phoenix Control Plane
├── Project & Identity
├── Narrative & Directing
├── Compilation
├── Workflow Runtime
├── Provider Registry & Router
├── Asset Registry
├── Quality & Review
├── Continuity
├── Timeline & Release
└── Audit, Rights & Budget

独立进程/服务
├── Media Worker
├── CV Worker
├── GPT-SoVITS Worker
└── 外部模型 Provider
```

模块之间通过应用服务和持久合同通信。只有在容量、故障隔离或团队所有权产生真实压力时，才按既有边界拆服务。

连续性相关的服务名与模块边界固定映射如下；即使部署在同一个 Phoenix 进程中，也必须使用独立应用服务、repository 写接口与数据库权限：

| 服务名 | 所属模块 | 允许写入 |
|---|---|---|
| Director Service | Narrative & Directing | planned Snapshot、planned StateTransition；不得写 Observation/Approval |
| QC / Annotation Service | Quality & Review / Quality 子模块 | DetectedObservation、QualityEvidence；不得写 planned/approved Snapshot |
| Review Service | Quality & Review / Review 子模块 | ReviewDecision、ContinuityApproval，并按批准事务创建 approved Snapshot；不得改 Narrative/ShotPlan |
| Continuity Service | Continuity | ContinuityEdge、比较报告与读模型；不得重写任一 endpoint |

`Quality` 与 `Review` 是同一部署模块中的两个权限边界，不共享通用“写任意质量表”repository。未来物理拆分只能沿上述边界进行，不能因为同进程部署而合并写权限。

## 1.6 写入边界

- UI、Agent 和 API 客户端只能提交 Command 或 ChangeProposal；
- Domain Service 负责权限、Schema、引用、状态守卫和乐观锁；
- 编译器不能直接推进人工批准状态；
- Provider Gateway/Adapter 只能经 Attempt Service、Request Snapshot Service 和受限 ingest API 写 ProviderAttempt、ProviderRequestSnapshot、用量和暂存结果；Generation Orchestrator 只发创建/取消/重生成命令，不直接写这些 repository；
- Analyzer 只能写证据；
- Timeline 不得修改源 AssetVersion；
- Release 只能引用已冻结的 TimelineVersion 和通过发布门的资产版本闭包。

## 1.7 MVP 系统验收不变量

1. 任一 Release 中的画面、声音、字幕都能追溯到输入 Revision、Provider Attempt、质量证据和批准者。
2. 重放相同 NodeRun 不会创建第二个逻辑副作用；故意生成候选则通过 candidate index 形成不同幂等作用域。
3. 接受偏差不会修改旧 Revision；修改事实会创建新 Revision 并计算影响范围。
4. 外部回调重复、乱序或延迟到达时，终态不会倒退，旧 Attempt 不会覆盖新选择。
5. 对象上传失败不会留下可批准 AssetVersion；孤儿对象可回收。
6. Rights 或 Budget 不满足时不会提交真实 Provider Job。
7. Stub、Manual 和 Unavailable 路径都有明确状态、责任人和恢复入口。
