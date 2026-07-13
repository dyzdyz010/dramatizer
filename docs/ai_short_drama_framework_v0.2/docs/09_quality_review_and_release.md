# 9. 质量证据、人工审核与发布合同

本章把“系统看到了什么”“规则建议做什么”“获授权的人决定了什么”分开保存。质量系统不得通过覆盖字段把概率判断伪装成事实，也不得把一次自动 `pass` 等同于资产已获批准。

## 9.1 对象边界与不可替代关系

质量链由五类不可互换的记录组成：

1. **`QualityEvidence`**：一次检查得到的指标、观察、定位和来源；只陈述证据。
2. **`AutomatedQualityDecision`**：指定策略版本对一组证据的可重放求值；是机器建议，不产生批准权。
3. **`ReviewDecision`**：获授权主体对候选资产、时间线或发布包的决定；是业务审批事实。
4. **`ContinuityApproval` / `CanonicalChangeProposal`**：处理生成结果与连续性期望不一致的两条路径；前者以 `accept_observation` 或 `manual_override` 接受受控偏差并生成 approved continuity snapshot，后者请求改变权威叙事事实。
5. **`ReleaseGate`**：对冻结的 `TimelineVersion` 和确定的导出资产集合做最终放行判断；不能复用候选 Shot 的 QC 结论代替整集检查。

所有记录均为追加式。纠正旧结果时创建新记录并通过 `supersedes_id` 关联；旧记录仍可审计。

## 9.2 两种质量范围

### 候选资产 QC（`candidate_asset`）

对象是一个不可变 `AssetVersion`，通常用于单 Shot 的一个 take。检查内容包括：

- 文件是否可用以及是否满足该 Shot 的媒体规格；
- 角色、台词、动作、场景、道具和机位是否符合 `GenerationSpecRevision`；
- 与进入 Shot 的 approved continuity state 是否相容；
- 是否值得批准、修复或重新生成。

候选 QC 的通过只意味着“可进入人工选择/批准”，不意味着它已进入时间线，更不意味着整集可发布。

### 整集发布 QC（`episode_release`）

对象是冻结的 `TimelineVersion`、导出配方和确定的导出 `AssetVersion`。至少检查：

- 最终文件可解码、时长、画幅、编码、音轨、响度、字幕安全区；
- clip 边界处黑帧、静音、爆音、重复帧、截断和 A/V 同步；
- 跨镜连续性、台词顺序、字幕同步、片头片尾和平台规格；
- 时间线中每个候选均有有效的人工批准或有效 waiver；
- 输入、声音、肖像、音乐、字体和输出用途的权利门均通过；
- 发布包清单、内容哈希、策略版本和审批链均被冻结。

任何时间线、导出配方、字幕或被引用资产内容/引用发生变化，都使原 `ReleaseGate` 失效并要求新的整集 QC。以下正交状态变化同样必须通过事件立即把 Gate validity projection 标为 `invalidated`，即使不可变 AssetVersion 本身没有改变：任一引用资产进入 `quarantined/restricted/deleted/orphan`；RightsGate 过期/撤销/用途变化；所依赖 waiver 到期/撤销；ReviewDecision 被 supersede；发布策略或目标变化。原 Gate 记录保留审计，不原地改写成“仍 ready”。

## 9.3 四层 QC 与统一执行状态

四层均使用同一组执行状态：

- `executed`：按指定 evaluator 与策略完成；
- `skipped`：适用但被显式跳过，必须有原因和授权依据；
- `not_applicable`：期望规则判定该层对当前对象不适用；
- `unavailable`：服务、模型或依赖暂不可用；
- `failed`：检查器自身失败，不能解释为被检对象不合格；
- `inconclusive`：执行成功但证据不足以形成可靠结论。

`skipped`、`unavailable`、`failed` 和 `inconclusive` 默认不能产生自动 `pass`；是否允许降级必须由版本化策略明确规定，并通常升级为 `manual_review` 或 `blocked`。新增/放宽此类降级策略属于高风险 Policy ChangeProposal，必须由 `quality_policy_admin` 审批、回放基准集并保存差异报告；普通候选 reviewer 无权临时启用。

### L1 媒体技术 QC

由 ffprobe、FFmpeg 和确定性规则执行，覆盖解码、时长、分辨率、帧率、画幅、编码、音轨、响度、削波、黑帧、静音、冻结、字幕安全区和导出规格。

策略中标记为 `hard_fail=true` 的失败会立即得到 `blocked`/`regenerate`，并可短路依赖可用媒体的后续层。例如无法解码时，不再把 Gemini/CV 的失败误报为内容缺陷。未依赖损坏媒体的权利或元数据检查仍可继续。

### L2 原生音视频语义 QC

Gemini 类原生视频模型理解事件、角色动作、情绪、台词语义、说话者、镜头运动及与导演意图的偏差。时间区间是语义定位，不是帧级真值。模型请求、模型版本、提示模板、采样参数、输入哈希和原始响应均需可追溯。

### L3 帧级/信号级 CV QC

基础 CV 与 L2 在 L1 通过后并行执行，基础项包括重复帧、冻结、闪烁、光流突变、人物数和音频活动区间。定向 CV 不是全量固定成本：它由 `GenerationSpecRevision` 的风险标签、L2 异常区间、基础 CV 异常或人工请求触发，执行身份跟踪、关键点、道具、口型/音画同步等专项检查。

触发决策也必须被记录：触发源、规则版本、目标时间范围和所选 evaluator 都属于证据链。

### L4 叙事/导演意图 QC

叙事 evaluator 接收权威叙事事实、导演方案、连续性期望、相邻镜头和前三层证据，评估叙事目的、表演、节奏和镜头关系。它可以建议修复范围或重生成，但不能修改 Canonical 数据，也不能作出人工批准。

## 9.4 检查项的最小证据合同

每个检查项至少保存：

- 稳定 `code`，以及 `outcome`（`pass/warning/fail/inconclusive`）；
- 可选 `metric`、`unit` 和结构化 `threshold`（操作符、目标/上下界）；
- `confidence`；确定性指标使用 `1.0`，不是省略置信度；
- 一个或多个证据定位：毫秒时间区间、帧区间、不可变资产引用和可选 artifact URI；
- evaluator 的名称、版本、种类和配置哈希；
- `policy_revision` 与 `expectation_revision`；
- 人可读说明和机器可用的 `details` 扩展。

没有期望修订就不能宣称“符合意图”；没有 evaluator/config 版本就不能重放；没有时间/帧/资产定位的语义结论只能作为低可操作性提示。

## 9.5 自动决策规则

决策引擎只读取已冻结的 QualityReport 输入并产生 `AutomatedQualityDecision`：

- `pass`
- `pass_with_warning`
- `manual_review`
- `repair`
- `regenerate`
- `blocked`

优先级固定为：技术硬失败 > 权利/安全阻断 > 必需 evaluator 未完成 > 确定性阈值 > 版本化组合规则 > 模型建议。决策保存消费的 evidence/check ID、策略版本、理由、短路层和结果哈希，保证相同输入可重放。

自动 `pass` 仅表示自动门未发现阻断项。候选资产仍需 `ReviewDecision(type=approve)` 才能被选入受控时间线；整集仍需独立 `ReleaseGate(status=ready)`。

## 9.6 人工审核与 waiver

`ReviewDecision` 的对象必须是不可变引用，允许：

- `approve`
- `reject`
- `request_repair`
- `request_regeneration`
- `waive`

审核界面必须展示期望、检测结果、异常时间/帧、模型与策略版本、上一次决定及被覆盖规则。决定记录 actor、角色、权限快照、理由、作用范围、时间戳和审计事件。

waiver 不能是一个布尔字段。它必须额外包含：

- `permission`：作出此类豁免所需并已验证的权限；
- `reason`：为何接受风险；
- `scope`：使用封闭的四选一合同，禁止混入不相关定位字段：`asset` 必须精确引用 `asset_version`；`shot` 必须精确引用 `shot_plan_revision`；`check` 必须精确引用候选资产或整集时间线并包含至少一个 `check_code`；`release` 必须精确引用 `timeline_version` 并包含非空 `release_gate_id`；
- `expires_at`：到期时间；永久例外应由更高权限的显式策略表达，不用伪造遥远日期；
- `audit_event_id`：不可变审计记录；
- 可选 `conditions`：例如“仅限内部预览，不得公开发布”。

waiver 到期、对象修订、范围变化或权限撤销都会使其失效，并通过定时器/事件使所有依赖 Gate validity projection 失效。权利缺失、恶意内容检出、恶意媒体隔离和法定禁止项是不可豁免类别。Schema 只能验证 waiver 结构，不能枚举随 Policy Revision 变化的检查 code；真正的安全边界是 Command handler 在创建 Decision 和每次发布 preflight 时按固定 Policy Revision 拒绝不可豁免 code，UI 不显示动作仅是易用性措施，不能作为授权控制。

## 9.7 连续性偏差的两条合法路径

当 detected end state 与 planned end state 不一致时：

### `ContinuityApproval`

`ContinuityApproval` 是领域连续性合同中的正式对象。使用 `accept_observation` 或 `manual_override` 接受当前候选偏差并指向新建的 `approved_snapshot_id`，记录输入 planned snapshot、detected observation、决定人、权限来源和理由。它更新的是获批准的生产连续性状态，不会改写 Narrative Canonical；下游只沿显式 `ContinuityEdge` 消费该 approved snapshot。

### `CanonicalChangeProposal`

认为偏差应成为新的权威事实时，提交独立变更提案，包含目标 Canonical revision、预期 JSON Patch、理由、影响分析和审批状态。只有提案被批准并应用后，才产生新的 Canonical revision、head pointer 变更和 stale 传播。模型输出或提案本身永远不是 Canonical 事实。

两者不可由同一操作暗中互换。审核人必须明确选择“批准观察/人工覆盖连续性”还是“提议改事实源”。

## 9.8 ReleaseGate 放行条件

ReleaseGate 绑定以下不可变输入：

- `TimelineVersion`；
- export recipe revision；
- 最终导出资产，以及由 Timeline/export/QC/Rights/Review/availability/policy 输入计算的 `gate_input_closure_hash`；
- 整集 QualityReport；
- 候选 ReviewDecision 集；
- rights-gate snapshot；
- 每个时间线输入资产及最终导出资产的 availability projection revision/hash（均须为 `available`）；
- 发布策略 revision。

状态为 `ready` 仅当：所有必需整集检查已执行并满足阈值；不存在未解决硬失败；所有时间线引用资产已批准且当前 availability 为 `available`；waiver 均有效且覆盖精确；权利门允许目标渠道、地域和时间；发布包哈希与所审对象一致。Gate 的 `valid_until` 取 Rights/waiver/policy 等依赖最早到期时间。否则为 `blocked`，或在策略允许且具备有效发布级 waiver 时为 `waived`。

ReleaseGate 不引用尚未创建的 ReleaseManifest。它的 `gate_input_closure_hash` 只覆盖 Gate 自身已存在的不可变输入；Gate 求值完成后计算其 canonical `release_gate_hash`。ReleaseManifest 只能在 Gate 为 `ready/waived` 且未过 `valid_until` 后创建，并固定 Gate ID/status/hash/input-closure hash、最终 Rights snapshot hash/valid-until，最后计算自己的 `manifest_hash`。`RenderInputManifest.input_closure_hash`、`ReleaseGate.gate_input_closure_hash` 与 `ReleaseManifest.manifest_hash` 是三个不同阶段的合同，禁止混用。

每次 PublishAttempt 发起外部副作用前必须即时 preflight：重新读取全部资产 availability、RightsGate、waiver、ReviewDecision 和 ReleaseGate validity，并把 result、policy revision 及各输入 hash 固定进 Attempt；任一 revision/hash 不同、状态非 available/allowed/有效或时间已过期，Attempt 以“确定未外发”的 preflight failure 结束，立即使旧 Gate/Manifest 不可发布并创建新 ReleaseCandidate，不得沿用旧幂等键。若提交中/已提交后 Gate 失效，则进入 cancelling + reconcile，不能假设尚未发布。发布幂等键至少包含 `release_gate_id + release_manifest_id + release_manifest_hash + platform + account`。发布后若发现问题，只能撤回/下架并创建新 Release，不得修改已发布记录。

## 9.9 并发、重放与可观测性

- 每次 evaluator 执行是独立 Attempt；重试不会覆盖前次输出。
- 报告聚合只接受输入哈希匹配的成功 Attempt，迟到结果进入审计但不污染新修订。
- 相同 evaluator/config/input/policy 可命中缓存；缓存命中仍生成带来源的 evidence link。
- 质量事件使用 outbox 发布；消费者用 event ID/inbox 去重。
- 指标至少覆盖各层耗时/失败率/不可用率、硬失败率、人工否决自动 pass 比例、waiver 数与到期数、重生成采用率和 ReleaseGate 阻断原因。

## 9.10 机器可验证合同

[`quality-report.schema.json`](../schemas/quality-report.schema.json) 定义报告、四层结果、检查项、证据定位、自动决定、人工决定、连续性处置和 ReleaseGate 的封闭结构；[`quality-report-example.json`](../examples/quality-report-example.json) 展示候选资产报告。实现可以通过显式 `extensions` 扩展，禁止在核心对象中静默增加未审字段。
