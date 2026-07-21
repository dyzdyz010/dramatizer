# Dramatizer 单用户实施对齐记录

**状态：** D-001 至 D-061 已完成对齐；后续调整继续只记录用户明确确认的方向性变更

**开始日期：** 2026-07-14

**上游设计基线：** `ai_short_drama_framework_v0.2/`

本文是 v0.2 面向单用户、本地优先实施的决策记录。v0.2 继续作为冻结的历史设计与机器合同基线，不在对齐过程中原地修改。本文与 v0.2 冲突时，后续单用户实施设计以本文已确认决策为准；尚未记录的事项不得据此推定已改变。

## 1. 产品与范围

### D-001：首个用户与运行边界

- 系统只服务项目所有者本人。
- 首版不需要认证、用户体系、RBAC/ABAC、租户隔离或权限管理。
- 首版是只监听 `localhost` 的本机 Web 应用，不部署到公网，也不制作原生桌面壳。
- 系统仍支持多个 `Project`；`Project` 只作为小说、解析结果、生产数据、资产和成本的组织边界，不承担安全隔离职责。

### D-002：移除安全与权利子系统

- 首版删除 `RightsGate`、素材许可记录、waiver、权利到期与发布前权利复核。
- 不保留伪造的 `allowed` Rights 快照。
- Provider 调用边界只预留未来可插入的 policy hook，首版不实现安全策略。
- 首版不实现多租户安全、prompt injection 防护、恶意媒体沙箱、legal hold 或安全审计等 v0.2 安全设计。
- Revision、状态机、幂等、资产 finalize、成本记录、QC 和人工选择继续保留；它们属于功能正确性与可恢复性，不属于本次删除范围。

## 2. 首个闭环与真实 AI 演进

### D-003：首个可运行闭环

- 输入一份最小剧集结构：1 集、1 场、3 个 Shot。
- 通过 Fake Provider 产生候选资产。
- 跑通 QC、人工选片、时间线组装和本地占位视频导出。
- 任意节点失败后可以继续运行，不必从头开始。
- 首个 Fake 闭环不要求真实文本、图像或视频模型参与。

### D-004：Fake 与真实 Provider 共用执行路径

Fake 与真实 AI 必须共用以下业务链路：

```text
GenerationSpec
→ Provider 路由
→ ProviderRequestSnapshot
→ Attempt
→ Adapter
→ UploadIntent / finalize
→ AssetVersion
→ QC
→ 人工选择
```

- Fake 和真实 AI 只替换 Adapter 实现。
- Fake 必须能够模拟异步执行、延迟、失败、超时、重复回调和成本。
- Fake 不得绕过运行时合同直接向数据库写入成功资产。

### D-005：首批真实 AI 能力

- Fake 闭环之后，首批同时接入文本生成和图像生成。
- 文本 AI 用于理解小说、补全角色与场景细节、形成导演/视觉提案和图像提示词。
- 图像 AI 用于角色、场景和镜头关键帧候选生成。
- 真实视频生成在文本与图像闭环之后接入。

### D-006：AI 提案与正式生产数据分离

```text
用户输入或小说来源
→ 文本 AI 结构化提案
→ 用户查看、编辑和确认
→ 不可变 Revision
→ 确定性编译
→ 图像 Provider 请求
```

- 文本 AI 输出不能直接成为正式生产输入。
- AI 可以生成角色、场景、导演意图和图像提示词提案。
- 用户确认后才创建正式不可变 Revision。
- 固定 Revision 闭包、编译器版本和策略版本必须得到相同的规范化 GenerationSpec 与 hash。

## 3. 小说导入与叙事解析

### D-007：小说是首版文本入口

- 首版必须支持导入小说并由文本 AI 自动生成后续生产所需的第一阶段数据。
- 小说导入后的第一阶段不直接生成 ShotPlan 或图像 Provider 请求。
- 第一阶段输出是可追溯的叙事解析包，包括章节/段落结构、人物与别名、地点、道具、人物关系、关键事件、故事时间线、原文位置和候选分集方案。
- 用户先选择并确认要制作的分集范围，系统随后生成该集的 Scene、Beat、角色/场景视觉设定和导演提案。

### D-008：导入格式

- 首版支持 UTF-8 TXT、Markdown 和带文本层的 PDF。
- PDF Parser 只支持文本 PDF。
- 扫描 PDF、图片 PDF 和 OCR 不在首版范围内。
- Parser 输出规范化全文，并保留可回到来源的定位信息：PDF 页码或文本字符偏移。

### D-009：整本分析策略

- 首版只实现 `whole_document` 分析策略，不按章节或语义段落切割后分别分析。
- 调用模型前必须计算输入 token，并为系统提示、结构化输出和安全余量预留空间。
- 文档能够容纳时整本提交；不能容纳时明确返回 `document_too_large`，不得静默截断。
- 分析层保留 `AnalysisStrategy` 接口，未来可以增加分层或分块策略。

### D-010：全文上下文、多任务调用

整本分析不等于一次模型调用完成全部工作。首版采用多次窄任务调用，每次都可以读取完整小说，分别生成：

1. 人物、别名与关系；
2. 地点、道具和世界设定；
3. 关键事件与时间线；
4. 候选分集方案；
5. 最终交叉校验与冲突报告。

每类结果可以独立验证、修复和重跑，避免用一个超大结构化输出承载全部解析结果。

### D-011：项目与小说来源模型

- 一个 `Project` 可以包含多份 `SourceDocument`，以支持多卷、番外和修订版。
- `volume/companion` 表示共同组成同一故事来源的文档。
- `replacement_revision` 表示替换旧源文件的新版本。
- SourceDocument Revision 不可变。
- 每次解析任务必须固定引用精确的 SourceDocument Revision 集合，不得隐式读取浮动的“最新文件”。

## 4. Provider、应用与基础设施

### D-012：首版 Provider 配置

- 首版不实现多 Provider 自动路由。
- `text_analysis` 配置一个真实文本 Adapter 和一个 Fake Adapter。
- `image_generation` 配置一个真实图像 Adapter 和一个 Fake Adapter。
- 系统仍保存 Provider、模型、参数和请求快照。
- Adapter 接口允许未来增加多个 Provider；健康度评分、配额路由、自动 fallback 和动态竞价不在首版范围内。

### D-013：控制平面与 UI 技术栈

- 控制平面采用 Phoenix + Ecto + Oban 模块化单体。
- 首版 UI 使用 Phoenix LiveView，不建立独立 Vue/React SPA。
- 文本解析、人工确认、任务状态和图像候选对比优先由 LiveView 实现。
- 未来复杂时间线可以作为独立前端组件加入。
- 媒体处理使用 Python/FFmpeg Worker 或受控外部进程。

### D-014：Rustler 使用边界

- Rustler 只用于经 benchmark/profiling 证明存在瓶颈的 CPU 密集型纯计算。
- 首选先用 Elixir 实现并测量，再决定是否下沉 Rust。
- 网络请求、数据库访问、FFmpeg 调用和普通业务逻辑不得为了“可能更快”而放入 NIF。
- Rustler NIF 必须限制输入、可取消，并使用适当的 dirty scheduler，避免阻塞 BEAM。

### D-015：数据库与资产存储

- 结构化数据和工作流状态使用 PostgreSQL。
- 首版本地素材使用文件系统 `AssetStore` Adapter，不运行 MinIO。
- 资产仍执行 `staging → hash/媒体校验 → content-addressed final` 流程。
- 本地文件系统与未来 S3/MinIO 实现共用 `AssetStore` 合同；替换存储 Adapter 不得改变资产状态机和业务引用。

### D-016：简化预算与成本模型

- 所有真实 Provider 调用均记录 CostEstimate 和 ActualCost；未知实际费用不能记为 0。
- 项目可以不配置预算上限；此时允许调用并持续记账。
- 项目配置预算上限时，调用前必须预留本次估算费用，余额不足则在外部调用前阻断。
- 调用结束后按实际费用结算并释放差额；并发任务共享同一项目预算时仍需通过数据库事务避免超额预留。
- 首版不实现预算审批角色、Budget HumanTask 或多级审批流。用户需要继续时，直接调整项目预算上限并重新发起任务。

### D-017：草稿与不可变 Revision

- AI 生成的结构化结果先进入可变 `Draft/Proposal`，不直接创建正式 Revision。
- 用户可以在 Draft 中反复编辑；普通编辑操作不为每次输入创建 Revision。
- 用户执行“确认”后，系统将规范化内容冻结为不可变 Revision，并记录来源 Draft、父 Revision、生成任务和内容 hash。
- 已确认 Revision 不允许原地修改。后续变更必须从该 Revision 派生新 Draft，再次确认后创建新 Revision。
- 旧 Revision 永久保留，既有任务、资产和发布结果继续引用当时的精确 Revision。

### D-018：全书分析与生产数据的确认粒度

- 文本 AI 对整本小说的每轮分析结果保存为不可变 `AnalysisSnapshot`，并固定 SourceDocument Revision 集合、模型、参数、提示版本和输出 hash。
- AnalysisSnapshot 中的人物、关系、地点、事件和时间线仍是 AI 分析结果，不要求用户逐条确认，也不直接成为正式 Narrative Authority。
- 用户首先查看并选择候选分集及其来源范围。
- 系统只将所选分集实际依赖的人物、地点、事件、对白和其他叙事数据物化为可编辑 Draft。
- 用户确认该分集 Draft 后，才创建正式 Narrative Revision；未被选中或未被物化的全书分析项继续留在 AnalysisSnapshot 中。

### D-019：原文事实、推断与创作补全分离

每项关键叙事或视觉数据必须声明来源语义：

- `source_grounded`：小说原文明示的事实，必须引用有效的 SourceDocument Revision 及页码或字符区间；
- `inferred`：模型根据上下文推断的结论，必须附依据位置并明确其并非原文明示；
- `creative`：为影视化主动补充的造型、色彩、镜头、环境或其他创作细节。

`inferred` 和 `creative` 不得伪装成小说事实。它们可以保留在 Proposal/Draft 中，并在用户确认后进入相应的 Narrative、Directing 或 Visual Revision；确认记录必须保留其原始来源语义。

### D-020：首版语言边界

- 首版只支持中文小说、中文工作界面和中文生产数据。
- Narrative、Directing 和 Visual Revision 的权威语义使用中文保存。
- Provider Adapter 可以根据目标模型需要，把已确认的中文语义确定性或受控地编译为其他语言的 Provider prompt。
- Provider 专用语言提示必须与中文输入 Revision、编译器/提示模板版本和最终请求快照一同保存。
- 翻译或 Provider prompt 不得反向覆盖中文叙事与导演权威数据。

### D-021：短剧规格默认值与两级覆盖

首版建议默认 ProductionProfile 为：

- 画幅：9:16；
- 单集目标时长：60–120 秒；
- 单集目标 Shot 数：10–30。

这些值不是系统硬编码限制。用户可以在 Project 层修改项目默认 ProductionProfile，也可以在 Episode 层为单集设置覆盖值；单集显式值优先于项目默认值。

### D-022：ProductionProfile 快照与非追溯规则

- 创建 Episode/Shot 正式 Revision 或启动 WorkflowRun 时，系统解析 Project 默认值与 Episode 覆盖值，并冻结一份有效 ProductionProfile 快照。
- 已启动或已完成的 WorkflowRun 永久引用启动时的快照；之后修改 Project/Episode 配置不会改变旧 Run 的输入或验收标准。
- 配置变更只影响之后创建的 Draft、Revision 和 WorkflowRun。
- 既有 Episode/Shot 若要采用新规格，必须显式创建新 Revision；既有执行若要按新规格生产，必须发起新的 WorkflowRun。

### D-023：模型配置的三级覆盖

- 系统级配置可用 Adapter、本地凭据引用，以及文本分析、图像生成等能力的默认 Provider、模型和参数。
- Project 可以覆盖系统级的 Provider、模型和默认参数；未覆盖字段继承系统值。
- 具体任务可以设置仅对本次执行生效的一次性覆盖；未覆盖字段继续继承 Project 或系统值。
- 解析优先级固定为：`task override > Project override > system default`。
- WorkflowRun/ProviderRequestSnapshot/Attempt 必须冻结解析后的完整有效配置；后续修改任何上游默认值都不改变历史执行。

### D-024：首批真实 Provider 映射

- 首个真实文本 Adapter 使用 OpenAI Responses API。
- 文本分析的系统默认模型为 `gpt-5.6-terra`；最终冲突校验等高要求任务可以使用一次性 task override 切换为 `gpt-5.6-sol`。
- 首个真实图像 Adapter 使用 OpenAI Images API 与 `gpt-image-2`。
- Gemini 首版不进入运行时，保留为后续文本/图像 Adapter 候选和效果对照。
- Claude ACP 用于开发过程与跨模型设计/代码审计，不作为 Phoenix 生产工作流中的模型 Provider。
- Suno 接口稳定后再作为音频阶段的候选 Adapter，本次文本与图像闭环不依赖它。
- 上述模型字符串属于可覆盖配置，不写死在领域数据或业务状态机中；实际执行继续按 D-023 固定有效配置快照。

### D-025：本地 API 凭据配置

- Provider API Key 只通过本机环境变量或 gitignored 的 `.env` 文件提供。
- 系统级模型配置只保存凭据引用名，不在 PostgreSQL、Project 配置、Revision 或 ProviderRequestSnapshot 中保存原始 Key。
- 首版设置 UI 只显示某个凭据引用是否可用，不负责展示或持久化原始 Key。
- 日志、错误信息、请求快照和导出文件不得包含 Authorization header、API Key 或带凭据的 URL。

### D-026：全书分析 DAG

全书分析按以下依赖执行：

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

- 三类初始抽取任务均读取完整规范化小说，可以并行执行。
- 实体消歧与合并必须等待全部 required 抽取任务完成。
- 候选分集必须基于合并后的实体、关系和事件结果生成，不得与初始抽取盲目并行。
- 最终冲突校验消费候选分集及其全部上游分析快照，并输出可定位的冲突报告。

### D-027：全书分析失败与重试

- 任一 required 抽取节点失败时，依赖它的实体合并、候选分集和冲突校验节点保持阻塞，不得使用不完整输入继续生成。
- 已成功节点及其输出永久保留，不因同一 WorkflowRun 中其他节点失败而回滚或重新执行。
- 用户可以单独重试失败节点；每次重试创建新的追加式 Attempt，不覆盖旧 Attempt、错误或输出。
- 重试默认复用原节点输入和有效配置，也允许通过 task override 为新 Attempt 修改模型或参数。
- 全部 required 上游成功后，调度器自动解除满足依赖条件的下游节点阻塞。

### D-028：结构化输出验证与修复

- 所有文本模型结构化输出先通过对应 JSON Schema 验证，再通过跨字段、引用范围、实体唯一性和领域不变量验证。
- 语法正确但缺少原文引用、存在重复/悬空实体或违反领域规则的输出仍视为无效，不得进入成功节点输出。
- 应用代码不得通过猜测、补默认值或删除错误字段静默修补模型结果。
- 首次验证失败后，系统最多自动创建两次结构化修复 Attempt，并向模型提供原输出、稳定错误码和精确 JSON Pointer/领域错误路径。
- 每次修复都是独立 Attempt，单独保存输入、输出、验证报告和成本，不覆盖原始响应。
- 两次修复仍失败时，节点进入 `failed`，等待用户调整 task override、选择其他模型或手工处理后再重试。

### D-029：两层 Prompt 合同

每个文本 AI 任务的最终提示由两层按固定顺序拼接：

1. `CorePrompt`：随代码版本化，用户不可见且不可修改；负责角色定义、输出 Schema、来源语义、领域不变量和禁止事项。
2. `PromptAppendix`：用户可见且可编辑；用于表达改编偏好、风格、任务重点和其他业务指导。

- PromptAppendix 不能替换、删除或重新定义 CorePrompt，只能作为受控附加输入。
- ProviderRequestSnapshot 必须固定 CorePrompt 的模板 ID/version、PromptAppendix 的精确 Revision/hash，以及拼接后实际提交内容的 hash。
- CorePrompt 发生变化时产生新模板版本，不得让旧 Attempt 看起来使用了新合同。

### D-030：PromptAppendix 的任务级作用域

- PromptAppendix 按 PromptTaskType 分别维护，不使用一份全项目通用文本影响所有模型任务。
- 首版至少区分人物/关系抽取、地点/道具/世界设定抽取、事件/时间线抽取、实体合并、候选分集、冲突校验、导演提案和图像提示词等任务类型。
- Project 为每种任务类型保存默认 PromptAppendix Revision。
- 启动具体任务时，用户可以基于 Project 默认值进行一次性编辑；本次有效 Appendix 随 ProviderRequestSnapshot 冻结，不回写 Project 默认值。
- 某任务类型的 Appendix 不得自动注入其他任务类型，避免创作偏好污染事实抽取或校验任务。

### D-031：Provider 调用无状态

- 同一小说分析 Workflow 中，各 NodeRun/Attempt 不共享或依赖 Provider 侧 conversation/thread 的隐式会话状态。
- 每个请求显式携带完整规范化小说、所需上游结构化快照、本次 CorePrompt/PromptAppendix 和有效模型配置。
- 修复 Attempt 显式引用原始输出与验证错误，不假设 Provider 仍保留上一轮上下文。
- Provider 返回的 conversation/response ID 可以作为诊断元数据保存，但不能成为重试、恢复或结果解释所必需的业务状态。
- 任一 NodeRun 必须能够仅凭数据库与 AssetStore 中固定的输入快照重新构造等价请求。

## 5. 视觉资产与图像候选闭环

### D-032：四层视觉生产链

角色、场景和道具的正式图像生产固定为：

```text
文本设定 Revision
→ VisualDesignRevision
→ ReferenceSetRevision
→ ShotKeyframe Candidate AssetVersion
```

- 文本设定 Revision 保存已经确认的叙事事实与来源语义。
- AI 基于文本设定补全外观、服装、色彩、材质、光照和禁止项，先形成可编辑 VisualDesign Draft；用户确认后才创建不可变 VisualDesignRevision。
- 参考图生成必须引用精确的 VisualDesignRevision；用户选定各槽位主图后创建不可变 ReferenceSetRevision。
- 正式 ShotKeyframe 生成必须引用精确的 ShotPlanRevision、VisualDesignRevision 和 ReferenceSetRevision，不得解析浮动的 `latest`。

### D-033：必须具备参考图的对象范围

- 常驻角色在进入正式 ShotKeyframe 生成前必须具备已确认的 ReferenceSetRevision。
- 跨多个镜头复用或剧情关键的场景、道具同样必须具备已确认的 ReferenceSetRevision。
- 只出现一次且非剧情关键的普通对象允许仅使用已确认文本设定生成，不强制先生产参考图。
- AI 可以建议对象是否属于“常驻、跨镜头或剧情关键”，但该标记必须进入分集/视觉 Draft 供用户确认；正式 Compiler 只读取已确认标记，不在执行时使用不可重放的隐式判断。

### D-034：Reference Set 类型模板与 Visual Variant

首版按对象类型提供可增删槽位的最小模板：

- 角色：面部近景、全身三分之四视角、表情/特征参考；
- 场景：空间全景、主要拍摄方向、关键光照版本；
- 道具：整体外观、关键细节或状态。

模板是创建 Draft 时的默认值，不是不可修改的硬限制。服装、年龄阶段、昼夜、季节、完好/损坏等会显著改变视觉语义的状态必须建立独立 `VisualVariant`，并由相应 ReferenceSetRevision 精确引用；不得用新图覆盖原状态。

### D-035：探索生成与正式生成分离

- 尚未确认的 VisualDesign Draft 或参考图候选可以用于探索性 ShotKeyframe 生成，以便快速试验造型和画面方向。
- 探索产物仍保存完整 GenerationSpec、Attempt、输入引用和 AssetVersion，但标记为非正式生产候选。
- 能够被正式选择并进入受控时间线的 ShotKeyframe，必须由已确认的 VisualDesignRevision 和 ReferenceSetRevision 编译生成。
- 将探索结果转为正式输入时不得原地改变其语义；必须先确认上游 Revision，再创建引用正式输入的新 GenerationSpec/Attempt。

### D-036：用户上传图与 AI 生成图共用资产路径

- 首版支持用户上传角色、场景和道具参考图。
- 上传图与 AI 生成图都必须经过同一 `staging → 校验/hash → finalize → AssetVersion` 路径。
- 用户可以把上传 AssetVersion 放入 Reference Set Draft，并在确认后由 ReferenceSetRevision 精确引用。
- 来源类型、原文件名、媒体探测结果和内容 hash 作为谱系元数据保存；业务下游不建立“上传图旁路”。

### D-037：图像候选数量默认值

- 基础参考资产的每次生成默认产生 4 个候选。
- 逐镜 ShotKeyframe 的每次生成默认产生 2 个候选。
- 系统提供上述建议默认值，Project 可以修改项目默认值，具体生成任务可以设置仅对本次 Attempt 集生效的一次性覆盖。
- 候选数量必须随 GenerationSpec/ProviderRequestSnapshot 冻结；修改默认值不追溯改变已创建的任务。

### D-038：主图选择、候选保留与图像编辑

- Reference Set 的每个模板槽位选择一个主 AssetVersion；多个槽位的主图共同组成一个 ReferenceSetRevision。
- 每个 ShotKeyframe 选择一个主候选供后续生产引用，未选候选继续保留并可用于比较或以后改选。
- 首版支持基于现有图片和编辑提示词继续生成；遮罩局部编辑预留 ProviderRequest 与谱系数据结构，但首版不实现遮罩画布 UI。
- 提示词编辑、重新生成和未来遮罩编辑都必须创建新的 GenerationAttempt 与子 AssetVersion，并保存父资产引用；任何操作都不得覆盖原文件或原 AssetVersion。

### D-039：首版图像候选采用两层 QC

首版静态参考图和 ShotKeyframe Candidate 只实现两层自动 QC：

1. `ImageTechnicalQC`：使用确定性媒体工具和规则检查文件可读取/解码、实际格式、宽高、画幅、最低分辨率及基础完整性；
2. `ImageSemanticQC`：使用支持图像输入和结构化输出的多模态文本 Adapter，对照精确 GenerationSpecRevision 与参考资产生成结构化质量证据。

- ImageSemanticQC 的系统默认模型为 `gpt-5.6-terra`，继续遵守 D-023 的 Project 与 task override；高要求复核可以一次性切换为 `gpt-5.6-sol`。
- 两层 evaluator 都必须保存实现/模型、配置、Prompt、输入闭包和输出 hash，重试创建新 Attempt，不覆盖旧结果。
- 首版不引入专用身份 embedding、人脸识别、姿态估计或其他独立 CV 模型；未来 evaluator 通过同一 QualityEvidence 合同追加。

### D-040：图像语义 QC 的标准检查维度

ImageSemanticQC 至少按以下独立维度输出 `pass/warning/fail/inconclusive`、置信度、理由及可操作建议：

- 角色身份与外观 VisualVariant；
- 服装、发型和其他已确认视觉特征；
- 场景、时间/光照和关键空间特征；
- 剧情关键道具及其状态；
- GenerationSpec 中的必须出现和禁止出现元素；
- 构图、景别、机位、动作和表情；
- 已确认视觉风格；
- 明显的肢体、文字、水印和其他画面伪影。

每个维度保留独立证据，首版不把全部判断压缩成一个不可解释的综合分数，也不开放用户自定义检查清单。

### D-041：只有确定性技术失败硬阻断

- 文件损坏、不可读取/解码或不满足 GenerationSpec 中硬媒体规格时，ImageTechnicalQC 产生硬失败；该 AssetVersion 不得成为 Reference Set 或 ShotKeyframe 的正式主图。
- ImageSemanticQC 属于概率性观察。即使某维度为 `fail`，系统也只能建议编辑、重生成或返回上游修改，不能自动否决用户选择。
- 用户可以明确接受带语义 fail、warning、inconclusive 或 evaluator failed/unavailable 状态的技术可用候选；系统保存当时的检查结果和可选说明，不引入 waiver、审批角色或权限合同。
- 自动 `pass` 同样不会自动选择候选；正式主图仍由用户的 SelectionDecision 产生。

### D-042：ShotKeyframe 一致性比较上下文

ShotKeyframe 的 ImageSemanticQC 固定读取：

1. 当前候选所绑定的精确 GenerationSpecRevision；
2. 当前 Shot 引用的精确 Character/Location/Prop ReferenceSetRevision 及其主 AssetVersion；
3. 存在时，叙事顺序上前后相邻且已选择的 ShotKeyframe AssetVersion。

- 第一或最后一个 Shot 缺少一侧相邻镜头时，仅使用存在的上下文，不视为错误。
- 首版不在每次候选 QC 中输入整集全部已选镜头。
- QualityReport 必须冻结实际使用的全部精确引用；相邻选择之后发生变化时，旧报告仍可重放，但其 freshness/失效规则由后续依赖传播决策确定。

### D-043：所有图像候选默认自动执行 QC

- AssetVersion finalize 后立即调度 ImageTechnicalQC。
- 技术上可用的每个参考图和 ShotKeyframe 候选自动调度 ImageSemanticQC，不等待用户先选出主候选。
- 候选只有在两层 QC Attempt 都进入终态后才进入正式可选状态；语义层的终态可以是正常报告、`failed`、`unavailable` 或 `inconclusive`，并按 D-041 交由用户判断。
- 候选画廊可以在 QC 运行时提前展示资产与进度，但不得把“尚未检查”伪装成 `pass`。

### D-044：候选画廊与人工选择体验

- 候选审核界面并排展示候选图、精确参考图、GenerationSpec 摘要和各维度 QC 证据。
- 系统可以根据确定性状态与语义结果排序或标记候选，但不自动预选或采用任何一张。
- 用户显式选择每个 Reference Set 槽位或 ShotKeyframe 的主 AssetVersion；其他候选保留。
- 用户接受带语义 fail 的候选时可以填写说明，但首版不强制填写，也不建立审批流。

### D-045：QC 修复入口不自动调用 Provider

QC 可以推荐动作，但不得因机器判断自动产生新的付费生成调用。用户可以明确选择：

1. 使用同一 GenerationSpec 创建新的生成 Attempt；
2. 以当前候选为父资产，通过编辑提示词创建图像编辑 Attempt；
3. 接受当前技术可用候选；
4. 返回上游修改 VisualDesign、ReferenceSet 或 ShotPlan Draft，确认新 Revision 后重新编译受影响的 GenerationSpec。

每种路径都保留原候选、原 QC 和原 Attempt。返回上游修改不得就地改变已确认 Revision；重新编译和后续生成只产生新的追加式对象。

## 6. 局部重生成与依赖失效

### D-046：通过影响预览 ChangeSet 采用新 Revision

- 创建新的 Narrative、VisualDesign、ReferenceSet、ShotPlan 或其他上游 Revision 后，现有生产链不会隐式切换到新 head。
- 系统沿精确 DependencyEdge 和 impact path 计算影响，生成 ChangeSet Draft，列出受影响的下游 Draft/Revision、GenerationSpec、QC、主候选选择、Timeline 和导出对象。
- 用户在影响预览中勾选本次升级范围并确认后，ChangeSet 才冻结精确旧/新 Revision、结构化 diff、选中对象和依赖图 epoch。
- 首版支持一次批量采用多个受影响对象，也允许只升级部分 Shot；未选对象继续精确引用旧输入。
- 单用户版本不建立 ChangeProposal 审批角色或权限流；“确认 ChangeSet”就是显式采用动作。

### D-047：自动增量重编译，不自动产生付费生成

- ChangeSet 确认后，系统自动为选中范围执行不含模型调用的确定性增量计算与编译。
- 需要人工创作确认的 Narrative、Visual 或 Director 变更只创建/更新 Draft；仍须按 D-017 确认后才能形成新的权威 Revision。
- 已具备全部确认输入的 Shot 自动产生新的 GenerationSpecRevision，并标记旧 Spec、候选、QC 和选择相对当前期望输入的 freshness。
- 系统不得仅因 ChangeSet 被采用就自动提交图像 Provider、产生新的 GenerationAttempt 或预留生成费用。
- 用户查看新旧 Spec 和影响范围后，显式选择要重新生成的参考图或 ShotKeyframe。

### D-048：stale 主图保留原选择并显式解决

- 已选 Reference Set 主图或 ShotKeyframe 变为 stale 时，原 SelectionDecision 和精确 AssetVersion 引用继续保留，界面必须醒目标记原因和受影响路径。
- 系统不得静默取消主图、替换成新候选或删除旧资产。
- 用户可以显式选择“继续固定旧输入”；该决定把当前生产分支固定在原 Revision 闭包上，并记录所接受的 stale reason/diff hash。
- 用户也可以采用新 Spec，重新生成或编辑候选并创建新的 SelectionDecision；旧决定和资产继续保留。

### D-049：stale 允许预览，正式导出前必须解决

- Animatic 和其他本地工作预览允许引用尚未解决的 stale 主图，但必须显示全局提示和逐项原因。
- 正式导出前，每个被 Timeline 引用的 stale 选择都必须有明确解决结果：继续固定旧输入，或升级并替换为新选择。
- “继续固定旧输入”是有效解决方式，不强制为了消除 stale 而重新生成视觉结果。
- 未处理的 `stale`、`unknown` 或 `impact_pending` 引用阻止创建正式 ExportRun；不会阻止用户继续编辑或查看工作预览。

### D-050：相邻主图变化只自动重跑局部语义 QC

- Shot 的主 AssetVersion 改选后，该 Shot 以及叙事顺序上前后直接相邻 Shot 的现有 ImageSemanticQC 报告因输入闭包变化而变 stale。
- 系统在短暂防抖窗口内合并连续改选，选择稳定后自动为上述最多三个 Shot 调度新的 ImageSemanticQC Attempt。
- 不存在的前/后邻居自然跳过；不会因一个 Shot 改选重跑整集 QC。
- 此自动行为只调用语义 QC，不自动重生成任何图片；新的 QC Attempt 继续记录模型成本和精确比较上下文。

### D-051：上游变化时在途任务的收尾规则

- 尚在排队、尚未创建 ProviderRequestSnapshot 或可证明尚未外发的旧输入节点转为 `superseded/cancelled`，不得再提交 Provider。
- 已经外发的 Attempt 不接受热更新。系统继续轮询、接收回调和完成费用/资产对账；Provider 支持可靠取消时，用户可以显式请求取消。
- 迟到或正常完成的旧输入结果仍经过 staging/finalize 并登记 AssetVersion，但标记其相对当前期望输入为 stale，不会自动成为主候选。
- 新输入使用新的 NodeRun/GenerationSpec/Attempt 和幂等键；旧任务的完成、失败或取消都不得改变新任务状态。

### D-052：ChangeSet 冻结计划并支持部分成功恢复

- 确认后的 ChangeSet 是不可变执行计划，固定精确输入 Revision、diff hash、选择范围、依赖图 epoch 和每个目标节点的预期动作。
- 各节点独立记录 `pending/running/succeeded/failed/skipped/superseded` 等执行状态；批次部分失败不回滚已经成功创建的不可变对象。
- 重试同一 ChangeSet 只执行失败或尚未执行的节点；已成功节点通过稳定幂等键返回原结果，不重复创建 Revision、Spec、Attempt 或费用记录。
- 用户可以从失败节点恢复，也可以基于剩余范围创建新的 ChangeSet；两者都保留与原计划的关系和执行历史。

## 7. 静态 Animatic 时间线与导出

### D-053：按 ShotPlan 自动创建可编辑 Timeline Draft

- Episode 具备 ShotPlan 顺序和主 ShotKeyframe 选择后，系统按 `proposed_shot_index` 自动创建首条 Timeline Draft。
- 每个 Shot 默认对应一个视频轨 TimelineClip，精确引用所选 ShotKeyframe AssetVersion，并使用 ShotPlan 的 `preferred_ms` 作为初始时长。
- 尚无主图的 Shot 仍创建带 Shot ID、预计时长和缺失原因的明显占位 Clip，使整集节奏可以在图像未全部完成前预览。
- 用户可以在 Timeline Draft 中重排、替换、增删和调整 Clip；这些操作不修改 ShotPlanRevision、SelectionDecision 或源 AssetVersion。
- ShotPlan 顺序变化不会静默覆盖用户已经编辑的 Timeline Draft，而是通过 ChangeSet/影响提示选择是否重新同步。

### D-054：Clip 时长默认跟随导演建议但允许越界

- TimelineClip 初始时长使用 ShotPlan `preferred_ms`。
- 时间线拖拽和数值编辑对 `minimum_ms/preferred_ms/maximum_ms` 提供吸附与可视提示。
- 用户允许把 Clip 调整到导演建议范围以外；系统显示节奏警告，但不禁止保存、预览或冻结。
- Timeline 时长是剪辑表达，不反向修改 ShotPlanRevision。若用户认为导演时长本身需要改变，必须另行派生 ShotPlan Draft 并确认新 Revision。

### D-055：首版提供有限、确定性的静态画面运动预设

- TimelineClip 支持 `static`、`push_in`、`pull_out`、`pan_left`、`pan_right`、`pan_up` 和 `pan_down`。
- 初始预设由确定性映射读取 ShotPlan camera intent 产生；同一输入和映射版本必须得到相同参数。
- 用户可以在 Timeline Draft 中更换预设和调整有限参数；效果只属于 TimelineClip，不修改源图或 ShotPlan。
- 首版不实现自由关键帧、贝塞尔缓动曲线、旋转或复杂合成画布。

### D-056：硬切默认，只增加简单叠化

- 所有相邻 Clip 边界默认使用 `hard_cut`。
- 用户可以为单个边界选择 `cross_dissolve` 并调整有限的转场时长。
- 转场时长必须参与总时长、字幕时间映射和 RenderInputManifest 计算。
- 首版不提供擦除、推拉、闪白、缩放或插件式转场库。

### D-057：从确认对白生成独立字幕轨

- 系统从 Timeline 所引用 ShotPlan 对应的精确 Narrative Revision 和 dialogue event 自动生成句级 SubtitleCue Draft。
- 用户可以调整 Cue 入出点、断句和显示样式；字幕轨与画面 Clip 分离，并随 Timeline Draft 保存。
- 仅改变断句、时间和呈现样式不创建 Narrative Revision。
- 修改字幕文字并改变对白语义时，UI 必须跳转到 Narrative Draft；确认新 Narrative Revision 后再通过 ChangeSet 同步字幕，不允许字幕轨成为隐式对白权威。
- 冻结 TimelineVersion 时固定字幕 Cue 内容、时间、样式配置和来源 Narrative Revision。

### D-058：文本与图像阶段使用显式标准静音音轨

- 首版静态 Animatic 不接 TTS、音乐、SFX 或 Suno 等音频 Provider。
- 渲染时生成覆盖完整时间线时长的标准 AAC 双声道静音轨，使输出 MP4 在播放器和后续音频管线中具有稳定的音轨合同。
- Timeline 和导出元数据明确标记 `audio_mode=silence_placeholder`，不得让用户误以为音频生产已完成。
- ShotPlan 的 audio_strategy 和 Narrative 对白引用继续保留，后续真实音频阶段可以替换占位轨而不改变画面资产谱系。

### D-059：预览代理与正式 Animatic 双路径

- Timeline Draft 可以按需生成缓存的低分辨率 Preview Asset；默认 9:16 ProductionProfile 下使用 540×960 H.264，以迭代速度优先。
- Preview 允许占位 Clip 和按 D-049 尚未解决的 stale 选择，必须在画面或播放器状态中显示提示；任何 Draft 变化都会使旧 Preview cache key 失效。
- 用户执行“冻结”后创建不可变 TimelineVersion，再创建固定输入闭包和 RenderProfile 的 RenderInputManifest。
- 默认 9:16 ProductionProfile 下，正式 Animatic 使用 1080×1920 H.264/AAC MP4；若 Project/Episode ProductionProfile 有显式覆盖，预览与正式尺寸按冻结的有效 Profile 等比例派生，而非写死为竖屏。
- 正式 RenderAttempt 输出 finalize 后的 AssetVersion，并执行独立导出技术 QC；预览缓存不能冒充正式导出资产。

## 8. 产品化工作台

### D-060：领域表单工作台与真实 AI 运行体验

- 项目工作区继续采用已确认的“引导式阶段导航＋持久项目工作区”，不改为一次性向导。
- Narrative、VisualDesign、ShotPlan、模型覆盖等面向用户的编辑面必须使用领域专用表单、可增删卡片、选择器和可读摘要；内部结构化 JSON 不得作为主要输入或确认结果直接展示给用户。
- 全书分析、分集叙事、视觉设计和导演方案按阶段形成真实文本 AI Proposal/Draft；AI 不得越过人工确认门直接创建权威 Revision。
- 参考图和 ShotKeyframe 继续由真实图像 AI 生成，图像提示词由文本 AI 在已确认中文权威数据上补足细节，不得反向覆盖权威数据。
- 常驻用户验收服务必须明确显示当前 Provider 与模型；配置了真实 Provider 的验收环境应实际运行 OpenAI 路径。Fake 仅用于自动测试、离线开发和显式故障演练，不得伪装成真实 AI 生产状态。
- 已确认 Revision 使用只读业务卡片、来源语义、版本和影响状态展示；调试所需的 ID、hash、请求快照和结构化 payload 进入可折叠诊断视图或运行详情，不进入普通创作表单。

### D-061：生产长任务采用持久异步执行与真实状态

- 全书分析、结构化 Proposal、图像提示词与生成、技术/语义 QC、预览和正式渲染不得在 LiveView 事件进程内同步执行；统一以 WorkflowRun/NodeRun 为持久执行包络并由 Oban Worker 处理。
- PostgreSQL 中的领域记录是唯一状态事实源；PubSub 只发送项目级失效通知，消息丢失、重复或乱序都不得改变最终正确性。页面重新连接后必须从数据库恢复状态。
- “已加入队列”只表示可追踪任务已被接受，不得提前宣称生成、QC 或渲染已经完成。界面必须区分 queued、running、failed、unknown remote state、ready 与需要人工确认的状态，并在持久任务活跃时阻止重复提交。
- 相同业务输入必须复用稳定 WorkflowRun、NodeRun、Attempt、Asset 和 RenderManifest；Worker 重复执行终态记录时无副作用，正式输出不得产生平行副本。
- Provider 请求提交后超时且无法确认远端结果时记录 `unknown_remote_state`，不自动创建新的付费请求；只有用户核对远端状态后才能决定继续处理。
- Worker 的执行权、Oban job identity、租约、退避和重试预算写入 NodeRun；异常终止由受控 Worker registry 和 Reconciler 恢复，不允许从数据库字符串动态创建任意模块。

## 9. 记录规则

- 本文只写入用户已经明确确认的决策。
- 每确认一个新决策，立即更新本文后再继续下一问。
- 被后续回答替换的建议不得同时保留为有效决定；需要修改对应条目并记录最终选择。
- 后续不再就默认尺寸、状态名、缓存、重试次数和其他可由既有不变量推导的实现细节逐项询问；由设计与实现过程直接确定并在最终 PRD/实施设计中记录。
- 只有会改变产品范围、核心用户流程、Provider/架构方向或 MVP 完成边界的选择才继续请求用户确认。
- 全部决策树对齐后，再将本文整理为完整实施设计并进行一致性审查。
