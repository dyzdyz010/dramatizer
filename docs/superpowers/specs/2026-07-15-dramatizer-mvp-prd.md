# Dramatizer 文本与图像 Animatic MVP PRD / 实施设计

**状态：** 待用户审阅

**日期：** 2026-07-15

**产品边界：** 本机、单用户、中文小说到静态 Animatic

**决策来源：** [`implementation-alignment.md`](../../implementation-alignment.md) D-001 至 D-059

**冻结上游参考：** [`ai_short_drama_framework_v0.2/`](../../ai_short_drama_framework_v0.2/README.md)

## 1. 产品定义

Dramatizer 是一个只监听 `localhost` 的个人 AI 短剧制作工作台。用户导入中文小说后，系统使用文本 AI 提取叙事结构、提出分集和视觉/导演方案；用户在关键边界确认不可变 Revision；系统再使用图像 AI 生成角色、场景、道具和逐镜关键帧候选，经过自动 QC 与人工选图后，组装并导出带字幕和静音占位轨的竖屏 Animatic。

首个 MVP 的价值不是“一键生成最终短剧”，而是建立一条真实、可追溯、可恢复、可局部重跑的文本与图像生产闭环。真实视频、配音、音乐和发布属于后续里程碑，但必须能够在不推翻当前数据合同的前提下接入。

## 2. 目标与非目标

### 2.1 MVP 目标

1. 把 TXT、Markdown 或文本 PDF 小说转为可追溯的整本分析结果和候选分集。
2. 把用户选中的分集物化为可编辑、可确认的叙事、视觉和导演 Revision。
3. 生成并管理角色、场景、道具参考图以及逐镜 ShotKeyframe 候选。
4. 在所有真实 Provider 调用中保留完整请求快照、成本、Attempt、资产和 QC 谱系。
5. 支持人工比较、选图、提示词编辑、局部重生成和显式上游变更传播。
6. 自动组装可编辑 Timeline，生成快速预览和正式静态 Animatic。
7. 任意节点失败或应用进程退出后，从已提交状态继续，不要求整条流水线重来。

### 2.2 首版非目标

- 用户注册、认证、权限、租户隔离或协作；
- RightsGate、许可、waiver、内容安全、恶意媒体沙箱或发布平台安全设计；
- OCR、扫描 PDF 或图片 PDF；
- 英文或多语言权威生产数据；
- 真实视频生成、TTS、配音、音乐、SFX、Suno 或平台发布；
- Gemini 运行时、Claude 生产 Provider、多 Provider 自动路由或 fallback；
- 自由曲线时间线动画、复杂合成、完整转场库或专业 NLE 替代；
- 云部署、对象存储集群、原生桌面壳或移动端。

## 3. 用户与成功标准

### 3.1 用户

唯一用户是项目所有者本人。系统可以管理多个 Project，但 Project 只是小说、生产数据、资产和成本的组织边界。

### 3.2 核心用户结果

用户能够完成：

```text
导入小说
→ 自动整本分析
→ 选择候选分集
→ 确认叙事 / 视觉 / 导演 Revision
→ 生成并选择参考图
→ 生成并选择 ShotKeyframe
→ 调整 Timeline 与字幕
→ 导出正式静态 Animatic
```

### 3.3 MVP 成功判定

- 使用 Fake Adapter 跑通 1 集、1 场、3 Shot 的完整路径，并在每个异步节点注入失败后恢复。
- 使用真实 OpenAI 文本和图像 Adapter，从一份可容纳的中文小说生成至少一个候选分集、所需参考图和 3 个 ShotKeyframe。
- 导出一个可解码、符合冻结 ProductionProfile、含字幕和 AAC 静音轨的 MP4 Animatic。
- 任一最终 TimelineClip 可追溯到 AssetVersion、QC、Attempt、ProviderRequestSnapshot、GenerationSpec、ShotPlan、Visual/Narrative Revision 和 SourceDocument Revision。
- 重复提交、重复回调、进程中断和局部重跑不产生重复逻辑副作用或重复成本记录。

## 4. 产品体验方向

首版采用“引导式阶段导航＋持久项目工作区”，而不是一次性向导或完全自由的素材库。

项目主导航固定为：

1. **来源**：导入文件、解析状态、SourceDocument Revision；
2. **全书分析**：分析 DAG、结果摘要、冲突和重试；
3. **分集**：候选分集、来源范围、叙事 Draft/Revision；
4. **视觉**：角色、场景、道具、VisualDesign 和 Reference Set；
5. **镜头**：ShotPlan、GenerationSpec、候选、QC 和选择；
6. **时间线**：Clip、字幕、预览和冻结；
7. **运行与成本**：WorkflowRun、NodeRun、Attempt、错误、用量和恢复动作。

系统在阶段内部尽量自动运行，在以下边界暂停等待用户：

- 选择候选分集；
- 确认 Narrative/VisualDesign/ShotPlan 等权威 Revision；
- 选择 Reference Set 与 ShotKeyframe 主图；
- 确认 ChangeSet 影响范围；
- 解决正式导出引用的 stale 项；
- 冻结 TimelineVersion 并发起正式导出。

## 5. 功能需求

### 5.1 Project、配置与 ProductionProfile

#### FR-001 Project 管理

- 创建、打开、重命名和归档多个 Project。
- 每个 Project 独立组织来源、Revision、运行、资产、成本和导出。
- 不建立用户或成员表，不对 Project 做权限校验。

#### FR-002 ProductionProfile

- 系统建议默认值：9:16、60–120 秒、10–30 Shot。
- Project 保存项目默认值，Episode 可以覆盖；Episode 显式值优先。
- 创建正式 Episode/Shot Revision 或 WorkflowRun 时冻结有效 Profile 快照。
- 修改配置只影响后续对象和运行，不追溯改变历史输入或验收标准。

#### FR-003 模型配置

- 配置优先级为 `task override > Project override > system default`。
- 系统级配置声明 Adapter、凭据引用、默认模型和参数。
- Project 可以覆盖默认值，具体任务可以设置一次性覆盖。
- ProviderRequestSnapshot 和 Attempt 固定解析后的完整有效配置。

#### FR-004 Prompt 合同

- 每种文本 AI 任务的最终提示按固定顺序由 `CorePrompt + PromptAppendix` 组成。
- CorePrompt 随代码版本化，用户不可见且不可修改，负责角色、Schema、来源语义和领域不变量。
- PromptAppendix 对用户可见且可编辑，按人物/关系、地点/道具/世界、事件/时间线、实体合并、候选分集、冲突校验、导演提案和图像提示词等 PromptTaskType 分别维护。
- Project 为每种任务类型保存默认 Appendix Revision；具体任务可以一次性编辑且不回写 Project 默认。
- ProviderRequestSnapshot 固定 CorePrompt 版本、Appendix Revision/hash 和最终拼接内容 hash；某任务的 Appendix 不得自动注入其他任务。

#### FR-005 语言边界

- 首版只支持中文小说、中文界面和中文权威生产数据。
- Narrative、Visual 和 Directing Revision 使用中文保存。
- Adapter 可以为目标模型生成受控的其他语言 Provider prompt，但必须保存与中文输入、模板/编译器版本和请求快照的关系。
- Provider prompt 或翻译不得反向覆盖中文权威数据。

### 5.2 小说导入与来源版本

#### FR-010 导入格式

- 支持 UTF-8 TXT、Markdown 和带文本层 PDF。
- PDF 不存在有效文本层时返回明确的 `text_layer_required`，不尝试 OCR。
- Parser 产生规范化全文，并保留 PDF 页码或文本字符偏移定位。

#### FR-011 SourceDocument Revision

- Project 可包含多份 `volume/companion` 文档及 `replacement_revision`。
- Revision 不可变；解析任务必须引用精确 SourceDocument Revision 集合。
- replacement 不自动重写旧 AnalysisSnapshot 或生产对象。系统计算影响并提示用户显式启动新的 whole-document 分析；旧生产分支继续可重放。

#### FR-012 整本输入预检

- 首版只实现 `whole_document` AnalysisStrategy。
- 调用前计算输入 token，预留 CorePrompt、Appendix、结构化输出和余量。
- 超过有效上下文时返回 `document_too_large`，不得截断或偷偷分块。

### 5.3 全书分析

#### FR-020 分析 DAG

```text
全文规范化
├── 人物 / 别名 / 关系抽取
├── 地点 / 道具 / 世界设定抽取
└── 事件 / 时间线抽取
          ↓
实体消歧与跨结果合并
          ↓
候选分集生成
          ↓
最终冲突校验
```

- 三个初始抽取节点读取完整小说并可并行。
- required 上游未成功时，下游保持阻塞。
- 成功节点不因兄弟节点失败而回滚；重试只创建新 Attempt。
- 最终结果保存为不可变 AnalysisSnapshot，不直接成为 Narrative Authority。

#### FR-021 结构化输出验证和修复

- 先执行 JSON Schema，再执行跨字段、引用范围、唯一性和领域验证。
- 禁止应用代码猜测模型意图或静默删除错误字段。
- 验证失败最多自动进行两次结构化修复 Attempt；仍失败则节点进入 failed，等待用户调整 task override 或手工处理。

#### FR-022 来源语义

关键叙事和视觉数据标记为：

- `source_grounded`：原文明示且带来源定位；
- `inferred`：模型推断且带依据定位；
- `creative`：影视化创作补全。

推断与创作不得伪装为小说事实。用户确认后仍保留原始来源语义。

### 5.4 分集、叙事和导演数据

#### FR-030 分集选择与物化

- 用户查看候选分集、来源范围、主要事件和冲突。
- 系统只把所选分集依赖的数据物化为可编辑 Draft。
- 用户确认后创建不可变 Narrative Revision；未选分析项继续留在 AnalysisSnapshot。

#### FR-031 Draft 与 Revision

- AI 输出只能进入 Draft/Proposal。
- Draft 可反复编辑；确认时规范化并冻结为不可变 Revision。
- 已确认内容的后续修改必须派生新 Draft 和新 Revision。
- 正式编译只读取精确已确认 Revision。

#### FR-032 ShotPlan 与确定性编译

- 文本 AI 提出 Scene、Beat、ShotPlan、视觉和导演 Draft。
- ShotPlan 保存呈现目标、镜头、动作、时长范围、声音策略、连续性和必须/禁止元素。
- ShotPlanRevision 到 GenerationSpecRevision 使用无模型调用的确定性 Compiler。
- 相同精确输入、模板、编译器和配置必须得到相同规范化 payload/hash。

### 5.5 视觉设计和参考资产

#### FR-040 四层视觉链

```text
文本设定 Revision
→ VisualDesignRevision
→ ReferenceSetRevision
→ ShotKeyframe Candidate AssetVersion
```

- AI 补全后的造型、色彩、材质、光照和禁止项先进入 VisualDesign Draft。
- 正式参考图必须引用已确认 VisualDesignRevision。
- 正式 ShotKeyframe 必须引用精确 ShotPlan、VisualDesign 和 ReferenceSetRevision。

#### FR-041 参考图要求

- 常驻角色必须有已确认 ReferenceSetRevision。
- 跨多个镜头或剧情关键的场景、道具必须有参考集。
- 一次性且非关键对象可以只用文本设定。
- AI 可建议对象分类，正式 Compiler 只读取用户已确认标记。

#### FR-042 Reference Set 模板

- 角色默认槽位：面部近景、全身三分之四视角、表情/特征。
- 场景默认槽位：空间全景、主要拍摄方向、关键光照。
- 道具默认槽位：整体外观、关键细节/状态。
- 服装、年龄、昼夜、季节、完好/损坏等显著变化建立独立 VisualVariant。
- 每个槽位选择一个主 AssetVersion；多个槽位组成 ReferenceSetRevision。

#### FR-043 上传资产

- 首版支持上传参考图。
- 上传图与 AI 生成图共用 `staging → 校验/hash → finalize → AssetVersion`。
- 下游只引用 AssetVersion，不建立上传旁路。

### 5.6 图像生成、候选和编辑

#### FR-050 Provider 路径

Fake 与真实 Adapter 共用：

```text
GenerationSpec
→ 配置解析
→ ProviderRequestSnapshot
→ Attempt
→ Adapter
→ UploadIntent / finalize
→ AssetVersion
→ QC
→ SelectionDecision
```

- Fake 模拟异步、延迟、失败、超时、重复回调和成本。
- 真实文本使用 OpenAI Responses API；默认 `gpt-5.6-terra`，高要求任务可覆盖为 `gpt-5.6-sol`。
- 真实图像使用 OpenAI Images API 与 `gpt-image-2`。
- Provider 调用无隐式会话依赖，每个请求可从本地快照完整重建。

#### FR-051 候选默认值

- 参考资产每次默认 4 个候选。
- ShotKeyframe 每次默认 2 个候选。
- 系统默认可被 Project 和具体任务覆盖；有效数量随请求快照冻结。

#### FR-052 探索与正式生成

- Draft 参考图可用于探索 ShotKeyframe，但探索产物不能直接进入正式 Timeline。
- 正式候选必须由已确认 VisualDesignRevision 和 ReferenceSetRevision 编译生成。
- 探索结果转正式时创建新 Spec/Attempt，不原地改变旧资产语义。

#### FR-053 图像编辑

- 首版支持现有图片＋编辑提示词生成子 AssetVersion。
- 遮罩编辑保留请求和谱系合同，但不实现画布 UI。
- 编辑、重生成和未来遮罩操作都创建新 Attempt 和子 AssetVersion，绝不覆盖原图。

### 5.7 图像 QC 和选择

#### FR-060 两层 QC

1. ImageTechnicalQC：文件、解码、格式、尺寸、画幅、最低分辨率和完整性；
2. ImageSemanticQC：多模态模型对照 GenerationSpec、参考图和相邻已选 Shot 输出结构化证据。

系统默认使用 `gpt-5.6-terra` 执行语义 QC。首版不引入专用身份、姿态或其他 CV 模型。

#### FR-061 语义维度

独立检查角色/Variant、服装、场景、光照、关键道具、必须/禁止元素、构图、机位、动作、表情、风格和明显伪影；每项输出状态、置信度、理由和建议，不压成一个不可解释总分。

#### FR-062 阻断规则

- 损坏、不可解码或违反硬媒体规格时禁止正式选择。
- 语义 fail/warning/inconclusive 或 evaluator failed/unavailable 不硬阻断技术可用资产。
- 用户保留最终选择权；接受语义 fail 时可以填写说明但不强制。
- 自动 pass 不自动选择资产。

#### FR-063 执行和界面

- Asset finalize 后自动运行技术 QC；技术可用的所有候选自动运行语义 QC。
- 候选画廊展示参考图、Spec 摘要、候选和逐维证据。
- 系统可排序但不预选；用户显式选择主图，其他候选保留。

### 5.8 变更、stale 和局部恢复

#### FR-070 ChangeSet

- 上游新 Revision 不自动切换现有生产链。
- 系统按精确依赖和 impact path 生成影响预览 ChangeSet。
- 用户选择升级范围并确认后，系统执行确定性增量计算与重编译，不自动调用付费生成 Provider。
- 确认后的 ChangeSet 固定精确输入、diff、图 epoch 和目标动作。

#### FR-071 stale 选择

- stale 主图保持原 SelectionDecision 和 AssetVersion，不静默取消或替换。
- 用户可继续固定旧输入，或采用新 Spec 后重生成/编辑并改选。
- 工作预览允许 unresolved stale 并显示提示；正式导出前必须逐项选择“固定旧输入”或“升级替换”。

#### FR-072 相邻 QC

- 改选 Shot 主图后，该 Shot 和直接前后邻居的语义 QC 变 stale。
- 防抖后只自动重跑这最多三个 Shot 的 ImageSemanticQC，不重跑整集，也不自动重生成图片。

#### FR-073 在途任务

- 未外发的旧输入任务转为 superseded/cancelled。
- 已外发 Attempt 不热更新，继续完成回调、费用和资产对账；结果按旧输入标记 stale。
- 新输入创建新 NodeRun/Spec/Attempt，旧任务终态不得覆盖新任务。

#### FR-074 部分成功恢复

- ChangeSet 各节点独立保存状态。
- 部分失败不回滚成功的不可变对象。
- 重试只执行失败/未执行节点，已成功节点返回幂等结果，不重复计费。

### 5.9 Timeline、字幕和 Animatic

#### FR-080 Timeline Draft

- 按 ShotPlan 顺序自动创建 Timeline Draft；每个主 ShotKeyframe 成为一个 Clip。
- 缺图 Shot 产生带预计时长的占位 Clip。
- 用户可重排、替换、增删和调整时长，不修改上游 Revision 或 AssetVersion。

#### FR-081 时长与视觉运动

- Clip 默认使用 preferred duration，并对 minimum/preferred/maximum 提供吸附。
- 用户可以越界，系统仅警告；若要改变导演建议，另建 ShotPlanRevision。
- 支持 static、push-in、pull-out 和四向 pan 预设；默认由 ShotPlan camera intent 确定性映射。
- 首版不做自由关键帧曲线编辑。

#### FR-082 转场

- 默认 hard cut。
- 单边界可选择 cross-dissolve 并设置有限时长。
- 转场参与总时长、字幕映射和渲染输入计算。

#### FR-083 字幕

- 从精确 Narrative dialogue event 自动创建句级 SubtitleCue Draft。
- 允许调整时间、断句和显示样式。
- 改变对白语义必须回到 Narrative Draft，确认新 Revision 后通过 ChangeSet 同步。
- 冻结 TimelineVersion 时固定字幕内容、时间、样式和来源 Revision。
- Preview 与正式 Animatic 默认把字幕渲染到画面安全区，同时生成与冻结 Cue 完全一致的 UTF-8 SRT sidecar AssetVersion，供后续音频/视频阶段复用。

#### FR-084 静音占位

- 首版不调用任何音频 Provider。
- 正式 Animatic 生成覆盖完整时长的标准 AAC 双声道静音轨，并标记 `audio_mode=silence_placeholder`。
- ShotPlan audio_strategy 和对白引用保留，供后续音频阶段复用。

#### FR-085 双路径导出

- Timeline Draft 按需生成缓存 Preview；默认 9:16 下为 540×960 H.264。
- 用户冻结不可变 TimelineVersion 后，创建 RenderInputManifest 和正式 RenderAttempt。
- 默认 9:16 下正式输出为 1080×1920 H.264/AAC MP4；其他 Profile 按冻结规格派生。
- 正式输出 finalize 为 AssetVersion，并执行独立技术 QC。Preview 不得冒充正式导出。

### 5.10 成本、运行状态和凭据

#### FR-090 成本

- 每次真实 Provider 调用记录 CostEstimate 和 ActualCost；未知实际费用不记为 0。
- Project 可不设上限；设置上限时，调用前事务性预留，结束后按实际结算。
- 余额不足时在外发前阻断；用户调整上限后重新发起，不建立预算审批流。

#### FR-091 API 凭据

- API Key 只来自本机环境变量或 gitignored `.env`。
- 数据库和配置只保存凭据引用名，不保存原始 Key。
- 请求快照、日志、错误和导出不得包含 Key 或 Authorization header。

#### FR-092 可恢复运行

- 工作流事实源是 PostgreSQL；Oban 任务只携带记录 ID，不携带不可恢复的内存状态。
- NodeRun 输入在入队前固定为 InputSnapshot。
- 外部回调写 inbox 去重，领域事件使用 outbox；重复和乱序消息不得让终态倒退。
- UI 显示 WorkflowRun、NodeRun、Attempt、资产和 QC 的独立状态，不压成一个模糊“项目状态”。

## 6. 系统架构

### 6.1 部署拓扑

```text
Browser
  ↓ localhost
Phoenix / LiveView modular monolith
  ├── PostgreSQL + Oban
  ├── local filesystem AssetStore
  ├── OpenAI text/image adapters
  └── supervised Python/FFmpeg media worker
```

- Phoenix 同时承担控制平面、领域命令、LiveView UI、工作流调度和 Adapter 编排。
- PostgreSQL 保存所有结构化事实、状态、幂等键、outbox/inbox 和成本。
- 本地 AssetStore 保存 staging、content-addressed final、preview 和 export 文件。
- Python/FFmpeg Worker 只处理解析/探测/渲染等媒体任务，通过版本化命令与结果合同交互。
- Rustler 仅在 profiling 证明 CPU 密集型纯计算瓶颈后引入；MVP 不预先使用 NIF。

### 6.2 Phoenix Context 边界

| Context | 责任 |
|---|---|
| `Projects` | Project、ProductionProfile 和项目设置 |
| `Sources` | SourceDocument、Parser、规范化文本和来源定位 |
| `Analysis` | AnalysisSnapshot、分析 DAG、结构化验证和修复 |
| `Narrative` | Episode、Scene、Beat、StoryEvent 和 Narrative Revision |
| `Visuals` | VisualDesign、VisualVariant 和 ReferenceSet |
| `Directing` | ShotPlan、连续性计划和确定性 GenerationSpec Compiler |
| `Generation` | Provider 配置解析、RequestSnapshot、Attempt 和 Adapter |
| `Assets` | UploadIntent、finalize、AssetVersion、内容哈希和 AssetStore |
| `Quality` | 技术/语义 QC、QualityEvidence 和 SelectionDecision |
| `Changes` | DependencyEdge、freshness、影响分析和 ChangeSet |
| `Timeline` | Timeline Draft/Version、Clip、字幕、预览和 RenderInputManifest |
| `Workflow` | WorkflowDefinition/Run、NodeRun、重试、取消、inbox/outbox |
| `Costs` | Estimate、reservation、actual 和 Project 预算投影 |

Context 之间通过公开命令/查询接口和 outbox 事件协作，不直接跨边界修改对方表。首版是一个发布单元和一个数据库，不为这些边界拆微服务。

### 6.3 关键领域原则

1. Logical ID、Revision ID、Attempt ID 和 AssetVersion ID 不混用。
2. AI 只能提出 Draft 或产生候选资产，不能直接写权威 Revision 或选择结果。
3. 不可变对象永不原地覆盖；head、选择和 freshness 是独立投影/决定。
4. `succeeded` Attempt 只代表产物完成 finalize，不代表 QC 或人工采用。
5. stale 是相对当前期望输入的派生状态，不代表历史对象损坏。
6. 所有外部副作用在数据库中先有可恢复意图和稳定幂等键。

## 7. 错误处理与恢复

### 7.1 稳定错误类别

至少区分：

- `invalid_input`：文件、Schema、引用或领域不变量错误；
- `document_too_large`：whole-document 超过有效上下文；
- `provider_rejected`：Provider 明确拒绝输入或输出；
- `rate_limited`：限流，可按策略退避；
- `provider_timeout`：外部执行超时；
- `unknown_remote_state`：提交结果不确定，必须先对账；
- `asset_finalize_failed`：媒体暂存成功但校验/登记未完成；
- `qc_failed`：evaluator 自身失败，不等同资产不合格；
- `budget_exhausted`：预算预留失败；
- `superseded`：输入已被用户确认的新 ChangeSet 替代。

### 7.2 重试原则

- Retry 复用同一逻辑作用域和输入，创建追加式 Attempt。
- Regenerate 明确请求新候选，使用新的 candidate index/幂等作用域。
- 用户修改 task override 后的重跑创建新 Attempt 并固定新配置。
- Provider user-correctable rejection 不盲目自动重试；先修改输入或提示。
- 迟到结果保留并标记来源，不覆盖更新的选择或运行。

## 8. 本地数据与备份

首版不实现云备份或灾备集群，但必须提供可验证的本地备份/恢复流程：

1. 暂停新写入并记录一致性检查点；
2. 导出 PostgreSQL dump；
3. 复制 content-addressed AssetStore 和 manifest；
4. 导出不含原始 API Key 的系统/项目配置；
5. 恢复后校验数据库引用、AssetVersion hash 和缺失 blob；
6. 通过固定 fixture 验证一个已完成 Project 可打开、回放谱系并重新导出同一 Animatic。

开发阶段可以先提供 PowerShell/Elixir Mix 命令和 runbook，不要求首版 UI 按钮。

## 9. 验收测试

### AT-001 Fake 三镜头闭环

给定 1 集、1 场、3 Shot fixture，Fake Adapter 产生候选并完成 finalize、QC、人工选择、Timeline、Preview 和正式 Animatic。每个 NodeRun 都能单独失败后恢复。

### AT-002 重复与乱序

注入重复提交、重复/乱序回调和 Worker 崩溃，最终每个候选槽位只产生一个逻辑采用结果，不出现重复成本或悬空可见资产。

### AT-003 小说分析

导入 TXT、Markdown 和文本 PDF，来源定位可回到原文；全书分析 required 节点失败时下游阻塞，重试不重跑成功兄弟节点。

### AT-004 结构化修复

模型返回非法 JSON、悬空引用和缺少来源定位时，验证报告给出稳定错误路径；最多两次修复后成功或收敛为 failed。

### AT-005 真实图像闭环

使用精确 VisualDesign/ReferenceSet/ShotPlan 生成至少两个 ShotKeyframe 候选；每个候选有请求、成本、AssetVersion、两层 QC 和人工选择谱系。

### AT-006 图像编辑与上传

上传图和 AI 图走同一 finalize 合同；提示词编辑产生带父资产引用的新 AssetVersion，原文件和旧候选 hash 不变。

### AT-007 ChangeSet 与局部重跑

修改一个角色 VisualVariant，只标记真正依赖的 Shot/候选/QC stale。ChangeSet 只重编译选中范围，不自动生成图片；失败节点可恢复且不重复成功结果。

### AT-008 Timeline 和导出

自动组装含占位 Clip 的 Timeline Draft；调整顺序、时长、运动、叠化和字幕后生成预览。冻结后导出的 MP4 可解码，分辨率/画幅/时长/视频编码/静音 AAC 轨和字幕安全区符合 Profile。

### AT-009 stale 导出门

未解决 stale 阻止正式 ExportRun，但不阻止 Preview。用户显式固定旧输入后可导出，导出闭包仍精确引用旧 Revision。

### AT-010 备份恢复

从数据库 dump、配置和 AssetStore manifest 恢复固定 Project；全部被引用资产 hash 匹配，历史谱系可查询，重新导出得到相同规范化 RenderInputManifest 和媒体配方。

## 10. 实施阶段

### Phase 0：应用与合同地基

- Phoenix/Ecto/Oban/LiveView、PostgreSQL、本地 AssetStore；
- Project、Revision、Workflow、Attempt、Asset finalize、inbox/outbox 和成本最小合同；
- Fake Adapter 与故障注入；
- 空库迁移和自动测试骨架。

### Phase 1：Fake 三镜头纵向闭环

- 1 集、1 场、3 Shot fixture；
- Fake 候选、技术 QC、人工选择；
- Timeline Draft、占位渲染、Preview 和正式本地导出；
- 失败恢复和重复回调验收。

### Phase 2：小说与真实文本 AI

- TXT/Markdown/文本 PDF Parser；
- whole-document token preflight；
- 分析 DAG、Schema/领域验证、两次修复；
- 候选分集、Narrative/Visual/Director Draft 与确认。

### Phase 3：真实图像生产

- OpenAI image Adapter；
- VisualDesign、ReferenceSet、上传、候选和提示词编辑；
- 两层图像 QC、候选画廊和 SelectionDecision。

### Phase 4：变更与完整 Animatic

- DependencyEdge、freshness、ChangeSet 和局部重跑；
- 相邻 Shot QC；
- 字幕、运动预设、叠化、静音轨和正式导出 QC。

### Phase 5：MVP 稳定化

- 全量验收 fixture、record/replay、成本对账和故障恢复；
- 本地备份/恢复命令与 runbook；
- 性能测量、长小说边界和 Provider 错误兼容；
- 确认后续视频/音频 Adapter 可以通过现有 GenerationSpec、Attempt、Asset、QC 和 Timeline 合同接入。

## 11. 风险与已选应对

| 风险 | MVP 应对 |
|---|---|
| 小说超过模型有效上下文 | 明确拒绝 `document_too_large`；保留 AnalysisStrategy 扩展点，不静默截断 |
| 不同小说格式差异大 | Parser 只规范化全文和来源定位；叙事结构由整本 AI 分析，不依赖固定章节切割 |
| 图像一致性判断不稳定 | 精确参考图＋逐维证据＋人工最终选择；语义 QC 不硬阻断 |
| Provider 费用失控 | Estimate、事务性预算预留、实际成本和禁止 QC 自动重生成 |
| 上游修改引发全量返工 | 精确依赖、impact path、ChangeSet 和局部重编译 |
| 进程崩溃或重复回调 | PostgreSQL 事实源、Oban、inbox/outbox、幂等和追加式 Attempt |
| 静态 Animatic 观感不足 | 有限推拉摇移、字幕和简单叠化；不提前引入视频 Provider |
| 本地资产与数据库不一致 | staged/finalize、内容寻址、启动/备份一致性扫描和 manifest 恢复验证 |

## 12. MVP 之后

按当前合同继续接入：

1. 真实视频 Provider 和视频候选 QC；
2. TTS/配音、音乐、SFX 与 Suno Adapter；
3. 多轨时间线和音频混合；
4. Gemini 视觉/视频 evaluator 或备用 Provider；
5. 更复杂的长文档 AnalysisStrategy；
6. 多 Provider 路由、fallback 和效果/成本比较；
7. 在确有需要时再设计公网部署、用户、协作和安全边界。

这些增强不得绕过现有 Revision、GenerationSpec、Attempt、AssetVersion、QC、SelectionDecision、ChangeSet、TimelineVersion 和成本合同。
