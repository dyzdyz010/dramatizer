# Dramatizer 生产工作台 v2 设计

**状态：** 方案 A 已确认；完整交互设计待最终审阅

**日期：** 2026-07-15

**适用范围：** 本机、单用户、中文小说到静态 Animatic

**需求基线：** [`2026-07-15-dramatizer-mvp-prd.md`](2026-07-15-dramatizer-mvp-prd.md)、[`implementation-alignment.md`](../../implementation-alignment.md) D-001 至 D-060

## 1. 设计结论

Dramatizer 不再把内部 JSON、数据库状态和测试入口直接拼成页面，而是成为一个由真实 AI 驱动的分阶段制作工作台：

```text
导入小说
→ 自动整本分析
→ 选择分集并生成 Narrative Draft
→ AI 生成 VisualDesign Draft
→ 生成/上传参考图并逐槽位选择
→ AI 生成 ShotPlan Draft
→ 确定性编译 GenerationSpec
→ 生成 ShotKeyframe、自动 QC、人工选图
→ 编辑 Timeline 与字幕
→ 预览、解决 stale、冻结并正式导出
```

阶段内自动运行到下一个人工门；AI 只能提出 Draft 或候选资产，用户确认后才冻结不可变 Revision 或 SelectionDecision。普通用户界面不展示可编辑 JSON。

## 2. 当前问题与设计目标

### 2.1 当前问题

1. 常驻服务运行在 Fake 模式，却没有在主界面明确告知用户，造成“模型没有接上”的正确观感。
2. Narrative、VisualDesign、ShotPlan 和模型参数直接暴露 JSON，用户必须理解内部数据合同才能完成业务操作。
3. VisualDesign 与 ShotPlan 由固定样例手填创建；已有文本模型、Prompt 和请求快照能力没有组成真实 AI 提案流程。
4. 分析结果只展示 DAG 状态，没有把人物、关系、地点、道具、事件、时间线、冲突和来源定位变成可审阅内容。
5. `Scene`、`Beat`、`StoryEvent`、`VisualVariant`、参考槽位、连续性、探索/正式、GenerationSpec、逐维 QC、ChangeSet 和 task override 等概念虽部分存在于后端，却没有形成完整用户心智模型。
6. 页面标题过大、有效信息密度低、表单布局破碎、状态和操作层级不清晰；运行详情与创作内容混在同一视觉层级。

### 2.2 设计目标

- 用户不看 JSON 也能完成完整闭环。
- 每一阶段只突出一个“下一步”，同时允许回看历史和派生修改。
- 真实 AI 的当前 Provider、模型、用量、运行状态和失败原因可见且不误导。
- 权威内容、AI 建议、自动观察、用户选择和运行事实在界面上明确分层。
- 所有 PRD 概念要么成为用户可操作对象，要么明确归入自动化/诊断层，不能只停留在表名或测试里。
- 保留现有 Revision、Attempt、AssetVersion、QC、ChangeSet 和 Timeline 合同，使未来视频、音频 Provider 可以直接接入。

### 2.3 非目标

- 不增加认证、权限、RightsGate、内容安全或协作流程。
- 不引入真实视频、TTS、音乐、SFX 或 Suno。
- 不做自由曲线、复杂合成或专业 NLE。
- 不把内部所有字段都变成高级选项；普通表单只呈现会影响创作和生产的业务字段。

## 3. 产品信息架构

### 3.1 全局框架

桌面端采用三层结构：

1. **顶部状态栏**：品牌、项目切换、保存状态、当前 Provider/模型、运行任务数和项目设置入口。
2. **左侧阶段栏**：来源、分析、分集、视觉、镜头、时间线、运行记录；显示完成度、等待用户、运行中、失败和 stale。
3. **主工作区**：当前阶段的创作画布；需要查看来源、版本、模型和 hash 时从右侧打开 Inspector，不挤占主表单。

设置不再塞进“运行记录”阶段。项目名称、ProductionProfile、模型覆盖、PromptAppendix 和凭据状态从顶部“项目设置”进入独立抽屉或页面。

### 3.2 全局下一步条

主工作区底部固定一条阶段动作栏：

- 左侧：当前草稿保存状态、阻塞原因和预计影响；
- 中间：本次动作使用的 Provider、模型、候选数及费用状态；
- 右侧：次要动作和唯一主动作，例如“确认 Narrative”“生成 4 组参考候选”“冻结并正式导出”。

危险或付费动作必须说明范围，不用模糊的“继续”按钮。

### 3.3 状态语言

统一使用以下用户状态，不把内部枚举直接输出：

| 用户状态 | 含义 | 主要动作 |
|---|---|---|
| 尚未开始 | 缺少前置输入 | 完成前一阶段 |
| AI 处理中 | 已有持久化运行 | 查看进度或取消未外发任务 |
| 等待确认 | Draft/候选已就绪 | 编辑、比较、确认 |
| 已确认 | 已冻结 Revision/Selection | 派生修改或进入下一阶段 |
| 需要处理 | 失败、冲突或 stale | 查看证据并执行明确恢复动作 |
| 已导出 | 正式输出可下载 | 查看谱系或派生新版本 |

内部 `WorkflowRun`、`NodeRun`、`Attempt`、资产和 QC 仍保留各自状态；界面只在运行详情中并列展示，不压成一个含混状态。

### 3.4 Project 首页

首页使用紧凑 Project 卡片展示名称、小说来源、当前阶段、最后活动、等待用户事项、运行中任务和最近正式导出。支持创建、打开、重命名和归档；归档 Project 默认折叠但不删除任何 Revision、运行或资产。新建 Project 后先进入 ProductionProfile 快速设置，再进入来源导入。

## 4. 视觉与交互语言

### 4.1 视觉方向

沿用“暖色纸面＋深墨色＋制作台橙色强调”的品牌方向，但改为紧凑的专业工作台：

- 页面背景为低对比暖灰，创作内容使用白色或深色实体面板；
- 主色只用于当前阶段和主动作，成功、警告、失败分别使用克制的青绿、琥珀和红色；
- 正文以 14–16px 无衬线字体为主，标题控制在 28–36px，不再使用占据半屏的展示字号；
- 采用 8px 间距系统、12px 卡片圆角、清晰分组和稳定列宽；
- 数据密集区优先使用列表、表格和可折叠详情，图片区优先使用画廊和对比视图。

### 4.2 卡片层级

- **Authority Card**：已确认权威内容，显示 Revision、来源语义和派生修改入口。
- **Draft Card**：AI Proposal 或用户编辑草稿，显示未保存/已保存、验证和确认动作。
- **Candidate Card**：资产候选，显示参考、QC、Attempt、费用和选择状态。
- **Run Card**：运行事实，显示输入、模型、进度、错误和恢复动作。
- **Alert Card**：冲突、stale、缺图或越界警告，必须附具体解决路径。

不同职责不复用同一种“普通白卡片”，避免权威、建议和观察看起来等价。

### 4.3 表单规则

- 标签使用中文业务名，帮助文字解释结果，不出现数据库字段名。
- 内部 ID 自动生成；默认隐藏，可在 Inspector 复制。
- 可重复实体使用可增删、可排序的嵌套卡片，不使用大文本框。
- 枚举使用单选、分段控件、复选标签或选择器；时长、比例和数量使用带单位输入。
- 字段错误就地显示，页面顶部同时给出错误摘要并可跳转。
- Draft 采用防抖自动保存并显示“已保存于 14:32”；确认前执行完整领域验证。
- 已确认 Revision 使用只读业务卡片；修改必须点击“派生新草稿”。
- 未被表单识别的历史扩展字段由兼容层保留，不允许一次保存意外删除。

### 4.4 来源语义

每个关键事实和创作字段都显示来源标签：

- **原文明示**：可打开原文定位，显示 PDF 页码或字符区间；
- **上下文推断**：显示依据定位和“并非原文明示”；
- **影视化补全**：显示为创作项，不伪装成小说事实。

新增或修改关键字段时可选择来源语义。选择“原文明示”或“上下文推断”时必须绑定至少一个来源定位；用户编辑不会销毁原 AI 分析项和原始定位。

## 5. 真实 AI 工作流

### 5.1 运行模式

- 常驻验收环境显式设置 `DRAMATIZER_PROVIDER=openai`，顶部显示“OpenAI 已启用”。
- 当前模型按任务显示，例如全文分析 `gpt-5.6-terra`、图像 `gpt-image-2`。
- 缺少凭据时禁用真实调用，显示凭据引用 `OPENAI_API_KEY` 不可用及修复方法；不回退到 Fake。
- Fake 仅在自动测试、离线开发或显式故障演练环境启用；Fake 模式显示全宽琥珀提示，所有相关按钮标记“模拟”。
- 普通 E2E 和单元测试继续强制 Fake，避免意外计费；真实 smoke 必须显式 `-Force`。

### 5.2 文本 AI 任务

完整任务目录包括：

| 阶段 | 任务类型 | 产物 |
|---|---|---|
| 全书分析 | `people_relations` | 人物、别名、关系 |
| 全书分析 | `places_props_world` | 地点、道具、世界设定 |
| 全书分析 | `events_timeline` | 事件与故事时间线 |
| 全书分析 | `entity_merge` | 实体消歧和统一引用 |
| 全书分析 | `episode_candidates` | 候选分集 |
| 全书分析 | `conflict_check` | 可定位冲突报告 |
| 分集 | `narrative_proposal` | Scene、Beat、StoryEvent、DialogueEvent Draft |
| 视觉 | `visual_design_proposal` | 角色、场景、道具、VisualVariant Draft |
| 镜头 | `directing_proposal` | Scene/Shot、连续性、导演和声音策略 Draft |
| 图像 | `image_prompt` | 受控 Provider prompt 提案 |
| 修复/QC | `structured_repair`、`semantic_qc` | 修复 Attempt 与逐维 QC 证据 |

新增的 Proposal 任务与现有分析任务一样使用隐藏 CorePrompt、任务专属 PromptAppendix、严格 Schema、领域验证和最多两次结构化修复。AI 成功只创建 Draft，不创建 Revision。

### 5.3 阶段自动化边界

1. 来源导入成功后自动启动整本分析；若同一 SourceRevision 集合已有成功 AnalysisSnapshot，则幂等复用。
2. 整本分析自动运行到候选分集完成或某节点稳定失败。
3. 用户选择分集后，系统物化依赖并执行 `narrative_proposal`，停在 Narrative 确认门。
4. Narrative 确认后自动执行 `visual_design_proposal`，停在 VisualDesign 确认门。
5. VisualDesign 确认后不自动产生付费图片；用户查看槽位和费用范围后显式生成参考图。
6. ReferenceSet 确认后自动执行 `directing_proposal`，停在 ShotPlan 确认门。
7. ShotPlan 确认后自动执行无模型的确定性 Compiler；用户显式选择 Shot 范围后才付费生成图片。
8. 候选 finalize 后自动执行技术/语义 QC，但绝不自动选择或因 QC 建议自动重生成。

这条规则实现“阶段内自动、关键边界暂停”，同时避免隐藏付费副作用。

### 5.4 一次性任务覆盖

每个 AI 动作旁有“本次设置”，默认折叠，显示当前有效配置摘要。展开后只显示适用于该任务的控件：

- 文本：模型、推理强度、任务 Appendix；
- 图像：模型、尺寸、质量、候选数量和本次补充说明；
- 语义 QC：模型、推理强度；
- 不适用的内部参数不显示。

本次设置只进入 ProviderRequestSnapshot，不回写 Project 默认。项目设置页可以另行保存项目覆盖。

## 6. 分阶段详细设计

### 6.1 来源

#### 页面结构

- 顶部显示支持格式、whole-document 策略和“不分段、不截断”的明确说明。
- 上传区支持 TXT、Markdown、文本 PDF，并显示文件名、类型、大小和上传/解析进度。
- 来源列表按 `volume`、`companion`、`replacement revision` 分组，显示不可变 revision 时间线。
- 每个 Revision 显示字符数、页数、内容 hash 简写、规范化状态和被哪些 AnalysisSnapshot 引用。

#### 解析预检

- 文本 PDF 无文本层时显示“该 PDF 没有可读取文本层，当前版本不支持 OCR”。
- token 预检显示正文估算、Prompt/输出预留和模型有效上下文余量。
- `document_too_large` 不截断；提供更换可容纳模型或返回来源的明确动作。
- 解析成功后自动创建 Analysis WorkflowRun，并导航到分析阶段。

### 6.2 全书分析

#### DAG 与运行

- 顶部以真实依赖图展示三个并行抽取节点、实体合并、候选分集和冲突校验。
- 每个节点显示模型、Attempt 数、耗时、用量和稳定状态；失败节点提供“查看错误”“本次设置”“仅重试本节点”。
- required 上游失败时，下游显示“等待人物/地点/事件节点”，不显示为普通未开始。

#### 结果审阅

结果区按标签页展示：

- 人物与关系：人物卡、别名、关系边和来源语义；
- 地点/道具/世界：实体卡、关键状态、出现范围；
- 事件时间线：按故事时间排序的 StoryEvent；
- 实体归并：合并前别名和统一逻辑实体；
- 冲突：冲突类型、涉及项、来源位置和建议处理。

点击任一来源标签在右侧 Inspector 展示原文上下文。AnalysisSnapshot 是不可变 AI 观察结果，因此这里只允许查看和重跑，不直接编辑成权威事实。

### 6.3 分集与 Narrative

#### 候选分集

候选以可比较卡片展示：标题、logline、来源范围、主要冲突、事件数、涉及人物/场景、预计时长、预计 Shot 数和冲突提示。用户只能显式选择一个候选进入当前制作分支。

#### Narrative 表单

Narrative Draft 由以下业务区组成：

1. **分集概览**：集名、logline、梗概、开场钩子、核心冲突、结尾悬念；
2. **单集规格覆盖**：目标画幅、时长和 Shot 数，留空继承 Project；
3. **Scene 列表**：顺序、标题、地点、时间/光照、目标、摘要和参与实体；
4. **Beat 列表**：所属 Scene、节拍目标、进入/退出状态和覆盖的 StoryEvent；
5. **StoryEvent**：事件类型、主体、动作、对象、因果关系、故事时间和来源语义；
6. **DialogueEvent**：说话人、正文、所属 Scene/Beat、叙事功能和来源定位；
7. **依赖实体**：人物、关系、地点、道具及是否需要进入视觉设计；
8. **冲突与待确认项**：来自分析的冲突、推断和影视化补全。

Scene、Beat、StoryEvent 和对白使用嵌套卡片与引用选择器，不能粘贴 JSON。确认前校验引用完整性、顺序、来源定位和 ProductionProfile。

#### 确认结果

确认后展示 Narrative Authority 摘要、Revision 号、父 Revision、Profile 快照和内容 hash。修改只能派生新 Draft；新 Revision 不自动替换已有视觉/镜头链，而是进入 ChangeSet 影响预览。

### 6.4 视觉设计与参考资产

#### VisualDesign 工作区

使用“角色 / 场景 / 道具”对象目录。左侧为对象列表，中间为对象表单，右侧为 Variant 与参考要求。

通用字段包括：名称、叙事作用、重要性、是否跨镜头复用、是否剧情关键、是否必须有参考图、来源语义、视觉总述、色彩、材质、风格、必须出现和禁止出现。

类型字段包括：

- 角色：年龄阶段、体态、面部、发型、服装、身份特征、表情范围；
- 场景：空间结构、时代/地域、关键方位、可见入口、时间/天气、主要光照；
- 道具：外形、尺寸感、材质、标记、关键细节、持有关系和状态。

#### VisualVariant

服装、年龄、昼夜、季节、完好/损坏等显著状态以独立 Variant 卡片存在。每个 Variant 有自己的名称、状态差异、必须/禁止项和参考槽位；创建新 Variant 不覆盖旧图。

#### 参考槽位

- 角色默认：面部近景、全身三分之四、表情/特征；
- 场景默认：空间全景、主要拍摄方向、关键光照；
- 道具默认：整体外观、关键细节/状态。

模板在 Draft 中可增删。界面明确区分“系统建议需要参考”和“用户已确认需要参考”；Compiler 只读取后者。

#### 候选生产与选择

VisualDesign 确认后，页面按“对象 → Variant → 槽位”展示生产矩阵。每个槽位可以：

- 上传已有图片；
- 使用 AI 生成默认 4 个候选；
- 查看由文本 AI 补足的图像提示摘要；
- 对比候选、精确参考和逐维 QC；
- 选择一个技术可用主图；
- 基于某候选输入编辑说明生成子 AssetVersion。

所有必需槽位都有主图后，用户确认 ReferenceSetRevision。未选候选永久保留。

VisualDesign 尚未确认时可以从对象或 Variant 卡片发起“探索生成”，用于快速验证视觉方向。探索候选同样保存 Spec、Attempt、资产、费用和 QC，但醒目标记“探索”；它不能成为正式 ReferenceSet 主图，也不能进入正式 Timeline。用户确认 VisualDesign 后若要沿用方向，必须基于正式 Revision 创建新的正式 Spec/Attempt。

### 6.5 镜头与导演方案

镜头阶段分为三个工作模式：**导演表单、生成规格、候选审核**。

#### 导演表单

Scene 作为分组，Shot 作为可排序卡片。每个 Shot 包含：

1. 标识和覆盖：所属 Scene/Beat、StoryEvent、镜头顺序、覆盖类型；
2. 呈现目标：观众应看到/理解/感受到什么；
3. 镜头类别：对白近景、双人、反应、动作、运镜、环境建立、物件特写、转场、群像；
4. 时长：minimum/preferred/maximum 和节奏理由；
5. 摄影：景别、角度、运动、视觉焦点、构图和镜头感；
6. 调度：地点 Variant、参与角色/服装 Variant、姿态、视线、情绪、强度、道具和走位；
7. 声音策略：无对白/对白权威/旁白、引用 DialogueEvent、对口型策略和声音备注；
8. 连续性：起始状态、镜内动作、结束状态、与前镜关系；
9. 约束：必须出现、禁止出现和精确参考对象。

快速编辑只展开常用字段；“完整导演参数”展开全部字段。缺失引用、时长次序错误、连续性冲突和必须/禁止项冲突在卡片内提示。

#### 连续性视图

镜头列表上方提供连续性轨道，展示人物服装/情绪、地点光照、关键道具状态与持有关系在相邻 Shot 的开始、动作和结束状态。它是 ShotPlan 的可编辑计划，不把 AI 观察伪装成事实。

#### GenerationSpec 视图

确认 ShotPlan 后由确定性 Compiler 生成只读 Spec 卡片，显示：

- 正式/探索标记；
- 精确 Narrative、VisualDesign、ReferenceSet、ShotPlan Revision；
- 中文权威摘要、参考图、必须/禁止项和媒体规格；
- 编译器/模板版本和 hash；
- 与上一 Revision 的结构化差异。

用户可以勾选 Shot 范围、查看候选数与费用估计，再显式发起生成。确认 ChangeSet 或编译 Spec 不自动调用付费图像 Provider。

#### 候选审核

候选按 Shot 分组，可切换画廊、两图对比和大图检查。每张卡展示：

- 候选图与精确参考缩略图；
- TechnicalQC 和 SemanticQC 独立状态；
- 角色、Variant、服装、场景、光照、道具、必须/禁止、构图、机位、动作、表情、风格、伪影逐维证据；
- 模型、Attempt、用量、费用和输入 freshness；
- 选择、重生成、提示词编辑、返回上游四类动作。

技术硬失败禁用正式选择；语义 fail/warning/inconclusive 允许用户选择并可填写说明。系统不自动预选。

### 6.6 Timeline、字幕与导出

#### 编辑布局

- 上方为 9:16 预览播放器和全局警告；
- 中间为可水平滚动的故事板时间线，Clip 显示缩略图、Shot、时长、运动和 stale/缺图状态；
- 下方为视频、字幕和显式静音占位轨；
- 右侧 Inspector 编辑当前 Clip、转场或字幕 Cue。

#### Clip 编辑

- 初始顺序和 preferred duration 来自 ShotPlan；缺图仍创建占位 Clip。
- 支持拖拽排序、替换主图、增删 Clip、数值时长、minimum/preferred/maximum 吸附和越界警告。
- 运动预设为 static、push-in、pull-out 和四向 pan。
- 默认 hard cut，可选择有界 cross-dissolve。
- Timeline 编辑不反向修改 ShotPlan 或 SelectionDecision。

#### 字幕

字幕从精确 Narrative DialogueEvent 创建。允许修改断句、入出点和安全区样式；修改语义时必须跳转到 Narrative 派生草稿，不能让字幕成为隐式对白权威。

#### 预览与正式导出

- Preview 允许占位和 unresolved stale，并在播放器和导出卡上显示水印式警告。
- 正式导出前运行清单检查：确认 Revision、技术可用选择、stale 解决、字幕时间、总时长和媒体规格。
- 用户冻结 TimelineVersion 后才创建正式 RenderInputManifest 和 RenderAttempt。
- 下载区区分 Preview 与正式 MP4/SRT，并显示 1080×1920 H.264/AAC 静音轨等冻结规格。

### 6.7 运行、成本与恢复

运行中心采用摘要＋可筛选明细：

- 摘要：运行中、等待用户、失败、今日用量、实际费用未知项；
- WorkflowRun 列表：工作流、阶段、开始时间、完成度和恢复状态；
- NodeRun/Attempt 时间线：输入版本、模型、请求 ID、用量、错误类别和重试；
- 成本账：estimate、reservation、actual 分开，Provider 未返回金额时显示“未返回”，不显示 0；
- 资产与 QC：可从 Attempt 跳转到生成资产和证据；
- 恢复动作：只重试失败节点、恢复部分 ChangeSet、对账 unknown remote state。

Fake 故障注入不出现在普通 OpenAI 运行中心，只在明确的开发/故障演练模式可见。

## 7. 变更、stale 与版本体验

### 7.1 Revision 历史

每种 Authority 都有版本条：当前生产分支、历史 Revision、父 Revision、创建来源和内容摘要。`latest` 不是隐式生产引用。

### 7.2 ChangeSet 影响预览

确认新上游 Revision 后，界面展示树状影响路径：

```text
VisualVariant 修改
├── 2 个 Reference 槽位
├── 6 个 GenerationSpec
├── 12 个候选及 QC
├── 3 个当前主图选择
└── 1 条 Timeline / 1 个旧 Preview
```

用户可以按对象或 Shot 勾选升级范围。确认页面明确说明：本次只做确定性重编译，不会自动生成图片或产生图像费用。

### 7.3 stale 解决中心

stale 不删除历史选择。每项显示旧输入、新输入、原因、受影响输出和两种合法动作：

- 固定旧输入：当前分支继续引用旧 Revision 闭包；
- 升级替换：采用新 Spec，生成/编辑并选择新候选。

Preview 可以继续；正式导出清单阻止未解决项。改选镜头主图后，只自动重跑当前和直接前后镜头的 SemanticQC。

### 7.4 在途任务与部分恢复

上游新 Revision 被采用时，界面分别说明：尚未外发的旧任务已取消、已经外发的 Attempt 将继续对账、迟到结果会保留但标为 stale。任何旧任务终态都不能覆盖新任务。确认后的 ChangeSet 显示逐节点执行状态；部分失败时只提供“从失败节点恢复”或“为剩余范围建立新 ChangeSet”，不回滚已成功对象。

## 8. 项目设置

### 8.1 ProductionProfile

以带单位表单显示 Project 默认值：画幅、目标时长、目标 Shot 数、Preview 和正式尺寸。分集表单显示继承值与 Episode 覆盖；留空即继承。历史 Revision/Run 显示冻结快照，不随设置回写。

### 8.2 模型配置

以任务矩阵展示：任务中文名、能力类型、系统默认、Project 覆盖和有效值。编辑 Project 覆盖时使用任务专属表单：

- 文本任务：模型和推理强度；
- 图像任务：模型、质量、尺寸和候选数量；
- 凭据只显示引用名和“可用/不可用”。

提供“恢复继承”动作。禁止编辑任意 JSON 参数。

### 8.3 PromptAppendix

按任务类型维护中文 Appendix，显示当前 Revision、更新时间、历史版本和影响范围。保存创建新 Appendix Revision；CorePrompt 只显示“由系统隐藏并版本化”，不展示正文。

### 8.4 凭据、预算与费用边界

- 凭据区只显示引用名、适用 Provider 和“可用/不可用”，绝不显示或保存原始 Key。
- Project 预算上限可留空；留空表示不阻断调用但继续记账。
- 设置上限时显示已预留、已结算和剩余额度；余额不足在外发前阻断，并提供“调整上限后重新发起”。
- 预算不是审批流，不引入角色或权限。

## 9. 表单与领域数据合同

### 9.1 类型化表单边界

为每类 Draft 建立独立表单模型，而不是在 LiveView 中手工解析 JSON：

- `NarrativeDraftForm`；
- `VisualDesignDraftForm`；
- `ShotPlanDraftForm`；
- `ModelOverrideForm`；
- `TaskOverrideForm`。

表单模型负责 cast、嵌套增删/排序、单位转换、字段错误和领域 payload 互转。领域 Context 继续负责跨对象验证、Revision 冻结和不可变规则。

### 9.2 Payload 版本

新 Draft payload 显式携带 schema version：

- `narrative-draft-v2`；
- `visual-design-draft-v2`；
- `shot-plan-draft-v2`。

兼容层读取现有简化 payload，补成表单可显示的默认结构；未知字段进入保留区并在保存时原样合并。确认时统一规范化，Compiler 只接收支持的已确认版本。

### 9.3 前端事件

每个表单按领域拆分 LiveComponent，使用稳定 ID 处理增删、排序和局部验证。LiveView 不把整个工作区做成一个巨大事件模块。需要复杂排序的 Scene、Shot 和 Timeline 使用最小 JS hook；业务写入仍通过 Context 命令完成。

### 9.4 校验

校验分三层：

1. 表单字段：类型、必填、范围和单位；
2. Draft 领域：引用、唯一性、时序、来源语义和必须/禁止冲突；
3. 确认门：前置 Revision、Profile 快照、版本兼容和完整输入闭包。

应用不得通过删字段或猜测模型意图让无效 AI 输出看起来成功。

## 10. 错误与恢复设计

用户错误使用中文标题、稳定类别和下一步：

| 类别 | 用户提示 | 可执行动作 |
|---|---|---|
| 输入无效 | 指出具体字段或文件问题 | 返回字段/重新上传 |
| 文档过大 | 显示 token 估算与模型上限 | 本次更换模型 |
| Provider 拒绝 | 显示脱敏原因 | 修改输入/本次设置后重试 |
| 限流/超时 | 显示已保留 Attempt | 重试失败节点 |
| 远端状态未知 | 禁止重复提交 | 先对账 |
| 资产 finalize 失败 | 显示暂存状态 | 恢复 finalize |
| QC evaluator 失败 | 不等同图片不合格 | 重试 QC 或人工判断 |
| stale/impact pending | 显示精确影响路径 | 固定旧输入或升级替换 |

Flash 只用于短反馈；需要用户处理的问题必须留在对应对象卡片和运行中心，刷新后仍可见。

## 11. 响应式与可访问性

- 以 1280px 以上桌面生产为主，960–1279px 折叠右侧 Inspector，左侧阶段栏缩成图标＋短名。
- 低于 960px 表单单列、候选横向滚动；不牺牲所有业务字段。
- 所有状态不只依赖颜色；按钮、表单和对话框有明确 label、焦点和键盘顺序。
- 拖拽排序同时提供上移/下移按钮。
- 图片有业务 alt；QC 证据和图像对比可用键盘访问。
- 运行中按钮防重复提交，并显示原地进度，不用全页遮罩。

## 12. 可观测性与诊断层

普通创作层不展示 JSON。右侧 Inspector 和运行详情允许只读查看：

- logical/revision/attempt/asset ID；
- hash、schema/compiler/prompt version；
- 精确依赖引用；
- ProviderRequestSnapshot 的脱敏配置摘要；
- 规范化 payload 的开发者诊断视图。

最后一项只在显式开发模式出现，默认关闭且不可编辑。API Key、Authorization 和隐藏 CorePrompt 永不进入页面、日志或导出。

## 13. PRD 概念覆盖矩阵

该矩阵定义每项需求在产品中的落点；“内部实现”不等于允许从用户流程中消失。

| ID | 用户界面落点 | 自动化/领域落点 |
|---|---|---|
| FR-001 | Project 首页创建、打开、重命名、归档 | Project 独立组织全部事实 |
| FR-002 | 项目设置＋Narrative 单集覆盖 | Revision/Run 冻结有效 Profile |
| FR-003 | 任务模型矩阵＋动作“本次设置” | system → project → task 解析并快照 |
| FR-004 | PromptAppendix 编辑和历史 | 隐藏 CorePrompt、最终 hash |
| FR-005 | 全部权威表单为中文 | Provider prompt 只读诊断关联 |
| FR-010 | 来源上传和文本层错误 | TXT/MD/PDF Parser |
| FR-011 | 来源类型和 Revision 时间线 | 精确 SourceRevision 集合 |
| FR-012 | token 预检和明确拒绝 | whole-document、不截断 |
| FR-020 | 分析 DAG 和结果标签页 | 持久化 required 依赖执行 |
| FR-021 | 节点错误路径和单节点重试 | Schema、领域校验、两次修复 |
| FR-022 | 原文明示/推断/创作标签与定位 | provenance 保留 |
| FR-030 | 候选比较和显式选择 | 只物化所选依赖 |
| FR-031 | Draft 自动保存、确认、派生修改 | 不可变 Revision |
| FR-032 | 完整导演表单和只读 Spec | 无模型确定性 Compiler |
| FR-040 | 视觉对象 → 参考矩阵 → 镜头候选 | 四层精确引用链 |
| FR-041 | 参考要求建议与确认开关 | Compiler 只读已确认标记 |
| FR-042 | Variant 和可增删槽位 | 槽位主图冻结 ReferenceSet |
| FR-043 | 槽位上传入口 | 上传/AI 统一 finalize |
| FR-050 | Provider/模型状态和运行详情 | Fake/OpenAI 共用执行路径 |
| FR-051 | Project 默认＋本次候选数 | 数量随 Spec/Request 冻结 |
| FR-052 | 探索/正式标记和使用限制 | 不同 Spec/Attempt 语义 |
| FR-053 | 候选编辑动作和父版本 | 新子 AssetVersion、不覆盖 |
| FR-060 | 候选卡两层 QC | finalize 后自动调度 |
| FR-061 | 逐维证据抽屉 | 结构化维度报告 |
| FR-062 | 技术失败禁选、语义失败可接受 | Selection 保存当时证据 |
| FR-063 | 分组画廊和显式选择 | 不预选、不自动重生成 |
| FR-070 | 影响树和范围勾选 | 冻结 ChangeSet、无付费副作用 |
| FR-071 | stale 解决中心 | 固定旧闭包或升级替换 |
| FR-072 | 相邻 QC 状态提示 | 防抖重跑最多三个 Shot |
| FR-073 | 在途任务说明 | cancel/supersede/迟到对账 |
| FR-074 | ChangeSet 节点与恢复动作 | 部分成功和幂等 resume |
| FR-080 | 故事板和占位 Clip | 按 ShotPlan 自动组装 |
| FR-081 | 时长吸附、越界警告、运动选择 | 确定性初始映射 |
| FR-082 | 边界转场 Inspector | hard cut/cross-dissolve 配方 |
| FR-083 | 独立字幕轨和回到 Narrative | Cue 冻结与 UTF-8 SRT |
| FR-084 | 显式“静音占位轨” | 全时长 AAC 双声道 |
| FR-085 | Preview/正式下载区和冻结门 | 两份 Manifest/Asset 路径 |
| FR-090 | 预算设置、成本账和未知金额 | estimate/reserve/actual |
| FR-091 | 凭据可用状态 | Key 只从本机环境读取 |
| FR-092 | 运行中心和恢复动作 | PostgreSQL 事实源、幂等事件 |

v0.2 中被 D-001/D-002 明确移除的认证、权限、RightsGate、安全工作台和发布权利概念不进入本工作台；它们不是遗漏。真实视频、音频、多 Provider 路由和复杂连续性观察/批准属于 PRD 明确的后续扩展，也不伪造成当前已完成能力。

## 14. 实施切片

实施按用户价值纵向推进，避免先搭一批空组件：

1. **工作台骨架和真实模式**：新全局框架、Provider 状态、独立设置、OpenAI 常驻启动；
2. **表单基础设施**：类型化表单、嵌套卡片、自动保存、Revision 只读卡和来源 Inspector；
3. **来源/分析/分集**：自动分析、结果审阅、候选比较和完整 Narrative 表单；
4. **视觉**：真实 VisualDesign Proposal、对象/Variant/槽位表单和参考生产矩阵；
5. **镜头**：真实 Directing Proposal、完整 Shot 表单、连续性、Spec 和候选审核；
6. **Timeline/变更/运行**：故事板时间线、stale 中心、影响树和运行成本中心；
7. **兼容与收口**：旧 Draft 兼容、响应式、可访问性、全量 E2E 和真实 OpenAI smoke。

每个切片都包含数据库/领域命令、LiveView、测试和实际浏览器验收，不把“页面长出来”当成完成。

## 15. 验收标准

### 14.1 体验验收

- 主流程任何一步都不要求输入、理解或复制 JSON。
- 用户能从界面辨认当前使用 OpenAI 还是 Fake、具体模型和凭据可用性。
- 每个阶段都有唯一主动作、明确阻塞原因和可恢复入口。
- AnalysisSnapshot、Draft、Revision、Candidate、QC、Selection 和 Attempt 的职责在视觉与文案上可区分。
- 所有确认内容都能以中文业务卡片审阅，并可回到原文定位。

### 14.2 功能验收

- 上传一份新的中文文本 PDF 后自动完成真实全文分析，并展示人物、地点/道具、事件、冲突和候选分集。
- 选择候选后，真实文本 AI 依次产生 Narrative、VisualDesign 和 ShotPlan Draft；用户通过表单编辑和确认。
- 用户通过对象/Variant/槽位生产矩阵生成真实参考图并确认 ReferenceSet。
- ShotPlan 能表达 Scene、Beat/Event 覆盖、时长、摄影、调度、声音、连续性和约束，并确定性编译 Spec。
- 候选审核展示完整两层 QC 和逐维证据，用户显式选择且可执行四类修复动作。
- Timeline 支持占位、重排、替换、时长、运动、叠化、字幕、Preview、stale 门和正式导出。
- 新 Revision 通过 ChangeSet 选择升级范围，不自动触发付费图像生成。

### 14.3 工程验收

- 单元、领域、LiveView、浏览器 E2E、合同、备份恢复和密钥扫描全部通过。
- Fake E2E 覆盖无费用完整路径；真实 smoke 使用新建 Project 覆盖文本 Proposal、图像、QC 与正式导出。
- 真实 smoke 的每个 Provider 调用都有脱敏 RequestSnapshot、Attempt、用量和成本事实。
- 常驻服务以 OpenAI 模式启动，HTTP 与浏览器烟测通过，用户已有 Project 数据不被清除。

## 16. 明确保留的后续扩展点

真实视频、音频、Suno、Gemini、Claude Provider、多 Provider 路由和复杂时间线以后继续复用：

```text
Revision
→ GenerationSpec
→ ProviderRequestSnapshot
→ Attempt
→ AssetVersion
→ QC
→ SelectionDecision
→ TimelineVersion
```

新增能力不得绕过当前权威、请求快照、成本、资产、QC、选择、ChangeSet 和时间线合同。
