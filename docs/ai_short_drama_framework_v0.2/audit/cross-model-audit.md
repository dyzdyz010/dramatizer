# v0.2 跨模型架构审计记录

**审计日期：** 2026-07-13  
**审计对象：** `docs/ai_short_drama_framework_v0.2`  
**结论：** 经多轮修复、跨模型挑战和独立回归后，未发现未解决的 P0/P1，可作为实施基线；真实基础设施和 Provider 行为仍须按路线图 Spike 与契约测试验证。

## 1. 审计方法

1. Codex 主设计线程先整合领域、运行时、质量/发布三条设计分支。
2. 独立只读 Codex 审计员对全部正文、Schema、示例和图进行敌对式审查，并构造非法负例。
3. 修复独立审计发现的 10 项 P1 与相关 P2 后，运行本地结构化验证。
4. Claude Sonnet 分别审计领域正文、运行时正文、质量/发布/安全/路线图正文。
5. 修复 Claude 发现的 P0/P1 后，将相关正文和 Schema 片段再次交给 Claude 做定向复核。
6. Claude 复核之后，独立 Codex 又执行两轮全量终审；每轮发现的问题都回写正文、Schema、正例和非法反例，再由同一审计员回归。
7. 最后把终审新增的 Rights/HumanTask/Prefilter 合同交给 Claude Haiku 做精确增量挑战，吸收其有效意见并对概念误判作出书面裁决。

Gemini 本地 CLI 未安装，`omx ask gemini` 无法运行；没有伪造 Gemini 结论。跨模型结论来自 Codex/GPT 与 Claude Sonnet 两个模型家族。

## 2. 第一轮独立审计与修复

独立 Codex 审计未发现 P0，但发现 10 项 P1：

- RenderInputManifest 与 ReleaseManifest 创建时机冲突；
- 平台发布 ACK 丢失无对账状态；
- GenerationTask 缺少 rights/manual/budget/no-route 闭环；
- ResolvedExecutionPlan 可携带 deny/null reservation；
- RightsGate 缺少机器合同；
- ProviderRequestSnapshot 未作为 Attempt 必填独立对象；
- ShotPlan 泄漏 Provider 名并允许候选成为对白权威；
- 正式编译确定性边界冲突；
- AssetVersion/UploadIntent finalize 负例可通过；
- waiver scope 可为空或无法精确定位。

以上均已修复，并补入正例与非法负例验证。相关 P2（成功候选空引用、连续性 kind/boundary/basis 条件、regenerate 实体层级）也一并修复。

## 3. Claude 审计与修复

Claude 分卷审计发现：

- 领域 P1：Continuity/Director/QC/Review 服务名未映射到控制平面模块与 repository 写权限；
- 运行时 P1：required HumanTask 只有 SLA 字段，没有 SLA 升级与 hard-deadline 终止迁移；
- 质量/安全 P0：AssetVersion 事后 quarantine 是正交投影，旧 ReleaseGate 可能不失效；
- 质量/发布 P1：waiver 到期未明确级联失效、render 前未重新求值 rights、发布幂等键未明确绑定最终 ReleaseManifest；
- 两项文档不一致：候选能力预筛与 RightsGate 顺序、render 前批准闭包 hash 复核。

对应修复：

- 在第 1 章加入服务到模块、允许写入和禁止写入的总表，并规定同进程子模块不得共享通用写 repository；
- 为 WorkflowRun、NodeRun、rights review、budget review 增加幂等 SLA escalation 和 required hard deadline 收敛路径；
- 统一为只读 Capability/Health/Quota 预筛 → 候选 RightsGate → 最终 Route/Cost/Budget → plan；预筛不构成授权；
- availability/restriction 变化即使不改 AssetVersion，也会使 pre-render eligibility、ReleaseGate、ReleaseManifest 和待提交 PublishAttempt 失效；
- ReleaseGate 固定 availability revision/hash 与最早 `valid_until`；ready/waived 时所有 availability 必须为 `available`；
- RenderInputManifest 创建及 RenderAttempt 前重新求值 render-use RightsGate 和 availability；
- waiver 到期/撤销通过事件与定时器级联使依赖 Gate 失效；
- ReleaseManifest 只能在最终 Gate ready/waived 且未过期后创建；PublishAttempt 绑定最终 manifest 并即时 preflight。

## 4. Claude 修复后复核

最终定向复核逐项确认以下 A–G 全部 resolved：

- A：模块和写权限映射；
- B：人工等待 SLA/hard deadline；
- C：预筛/Rights/Route 顺序；
- D：quarantine 触发 Gate 失效；
- E：waiver 到期级联；
- F：render 前 rights 复核；
- G：发布幂等明确绑定 ReleaseManifest。

Claude 最终 Verdict：全部 7 项 P0/P1 均已闭合，未发现新的 P0/P1。

## 5. Claude 复核后的独立终审

Claude A–G 复核之后，独立 Codex 全量终审仍找出第一批 2 项 P0、4 项 P1：

- render-use eligibility 之前就创建 RenderInputManifest，存在门禁顺序绕过；
- PublishAttempt `begin_submit` 缺少紧邻副作用的完整 publication preflight；
- HumanTask 的 SLA/hard deadline 仍停留在文字，未进入机器合同；
- ReleaseGate 与后创建 ReleaseManifest 之间存在 `manifest_hash` 循环语义；
- Candidate prefilter 顺序没有正式状态和证据绑定；
- GenerationAttempt/ContinuityApproval 的唯一写入者在章节间冲突。

修复后，第二轮终审再发现 1 项 P0、2 项 P1：Rights Schema 无法表示 `render/internal_export`；普通/预算 HumanTask 只有 Definition 模板、没有运行时对象；CandidatePrefilterSnapshot 仍只是 opaque ID/hash。最终修复包括：

- `scope=render` 与 `purpose=internal_export` 的条件 Schema、真实 render Rights snapshot 和错误用途反例；
- 通用/预算 HumanTask 的 owner、输入 hash、状态、claim、SLA、hard deadline、escalation、action 合同，NodeRun/GenerationTask 引用和到期终态；
- 完整 CandidatePrefilterSnapshot，固定 Spec/intended-use/Catalog/Health/Quota/RoutePolicy 和逐 Provider 证据，并由 ResolvedExecutionPlan 绑定 ID/hash；
- ReleaseGate 使用独立 `gate_input_closure_hash`，ReleaseManifest 后续固定 canonical `release_gate_hash` 与自身 hash；
- RenderInputManifest 只在 eligibility 成功事务中创建，RenderAttempt/PublishAttempt 前即时重读全部门禁输入。

独立终审最终结论：`no unresolved P0/P1`。

## 6. 最终 Claude 增量挑战与裁决

Claude Sonnet 对最终大输入的两次调用在本机超时；没有伪造结果。随后 Claude Haiku 读取精确 Schema 片段，对三个新增合同做定向挑战：

- 明确确认 `render → internal_export` 条件绑定正确、无 P0；
- 提出 RightsHumanTask 同时存在 `expires_at/hard_deadline_at` 会产生歧义，以及通用 `deadline_expired` 缺少字段互斥；两项均已采纳：移除 task `expires_at`，并给专用/通用任务增加到期时间与非到期状态互斥反例；
- 把 `eligible_provider_count`、跨聚合外键视为 JSON Schema P1，但这些是文档明确分配给事务/领域 validator 的跨记录不变量；保留为实施测试项而非遗漏合同；
- 把输出 `GenerationTask.candidate_count` 与可用 Provider 数错误等同；两者是正交维度，正文已明确禁止相等比较。

采纳意见后再次运行独立 Codex 回归与本地验证，仍为 `no unresolved P0/P1`。

## 7. 本地验证证据

- 8 个 JSON Schema：Draft 2020-12、meta-schema、format、唯一 `$id` 全部通过；
- 7 个正例全部通过对应 Schema；
- 2 个派生正例通过：有效 check waiver、仅含 available 资产的 ready ReleaseGate；
- 33 个非法负例全部被拒绝，除原有领域/连续性/执行/资产/质量边界外，还覆盖 prefilter 内容与 plan 绑定、render/internal-export、通用/预算/Rights HumanTask deadline、到期字段互斥、ReleaseGate hash 拓扑、PublishAttempt 完整即时 preflight；
- 所有本地 Markdown 链接有效；
- 4 张 Mermaid 均实际渲染成功。

验证入口：[`../tools/validate_contracts.ps1`](../tools/validate_contracts.ps1)。

## 8. 实施期仍需验证的风险

以下不是未解决设计 P0/P1，而是实现必须用 Spike/测试退休的风险：

- 数据库唯一约束、租户边界、exact ref 类型、DAG 无环、跨数组数量和金额汇总；
- 对象存储 conditional copy/HEAD、orphan reconciliation 与故障注入；
- 真实 Provider 能力、定价、配额、回调签名、查询/取消和幂等语义；
- 发布平台按 submission key/hash 查询既有发布的能力与人工对账 SLA；
- Rights/waiver/policy 到期定时器和失效事件的时钟、乱序、重复投递测试；
- HumanTask 最终 action 属于该任务 `allowed_actions`、owner/FK 存在和到期事务的领域 validator；
- `eligible_provider_count` 与结果计数、ResolvedPlan 只能选择对应 prefilter snapshot 中 eligible Provider/model 的事务约束；
- 质量阈值、不可豁免 code、模型提示注入和恶意媒体红队验证；
- typed extension 注册表的二次 Schema 验证。
