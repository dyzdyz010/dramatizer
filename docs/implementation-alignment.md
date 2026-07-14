# Dramatizer 单用户实施对齐记录

**状态：** 持续对齐中，仅记录已由用户明确确认的决策

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

## 5. 记录规则

- 本文只写入用户已经明确确认的决策。
- 每确认一个新决策，立即更新本文后再继续下一问。
- 被后续回答替换的建议不得同时保留为有效决定；需要修改对应条目并记录最终选择。
- 全部决策树对齐后，再将本文整理为完整实施设计并进行一致性审查。
