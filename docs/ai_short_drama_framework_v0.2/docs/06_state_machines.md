# 6. 分实体状态机与写入权限

## 6.1 为什么必须拆分状态轴

v0.1 的 `draft → generating → qc_failed → approved → released` 把内容成熟度、异步执行、产物质量、人工裁决和发布关系压成了一个字段。该模型无法回答“内容已批准但生成失败”“候选 QC 失败但被授权 waiver”“已批准资产尚未进入时间线”等正常问题。

v0.2 使用相互正交的状态轴：

```text
ContentRevision maturity     内容是否可作为固定输入
WorkflowRun / NodeRun        编排是否在运行、等待或结束
GenerationTask               N 个候选这一业务意图是否完成
ProviderAttempt              一次 Provider 副作用是否完成
Asset ingest / QC            字节是否可用、证据是否满足门禁
ReviewDecision               获授权主体作了什么裁决
TimelineVersion              剪辑版本是否冻结
Release                      冻结闭包是否已批准和发布
```

这些状态不能相互代写。Provider Attempt 成功不会批准资产；资产获批不会自动加入 Timeline；Timeline 引用资产也不会修改 ShotPlanRevision。

## 6.2 通用迁移合同

所有状态迁移命令必须携带：

- `entity_id`、`expected_state` 和乐观锁版本；
- `command_id`/业务幂等键；
- actor（用户、服务账号或确定性策略）及权限域；
- 原因、关联 Workflow/Attempt/Asset ID；
- UTC 时间和 trace context。

状态变化与审计事件、必要的 outbox 记录在同一数据库事务提交。重复命令返回首次结果。终态回调只可补充幂等审计材料，不能令状态倒退。管理员修复也必须发出显式补偿事件，禁止直接改表。

## 6.3 Content Revision 成熟度

Revision 内容写入后不可变；下表状态是独立的成熟度投影，不允许借状态迁移修改 payload。

| 当前状态 | 命令 | 下一状态 | 守卫 |
|---|---|---|---|
| `draft` | submit | `proposed` | Schema、引用和权限校验通过 |
| `proposed` | approve | `approved` | 审核者有相应内容域权限；无未解决 hard finding |
| `proposed` | request_change | `draft` | 记录反馈；实际内容修改必须创建新 Revision |
| `draft` / `proposed` | withdraw | `withdrawn` | 未被已冻结 Release 闭包要求 |
| `approved` | supersede | `superseded` | 存在同 logical entity 的后继已批准 Revision；旧 Revision 保留可重放 |

`withdrawn` 和 `superseded` 为终态。执行只接受策略允许的成熟度，默认要求 `approved`。head pointer 指向哪个 Revision 与 Revision 自身成熟度是两件事。

**写权限：** Narrative/Director Domain Service 根据授权命令写入；编译器、Provider、QC Worker 不得写。

## 6.4 WorkflowRun 状态机

| 当前状态 | 事件 | 下一状态 | 守卫 |
|---|---|---|---|
| `created` | enqueue | `queued` | Definition 版本存在；输入快照固定；run 幂等键唯一 |
| `queued` | worker_claimed | `running` | 未请求取消；队列 lease 有效 |
| `running` | human_gate_reached | `waiting_human` | 至少一个 required NodeRun 为 `waiting_human`，无可运行 required 节点 |
| `waiting_human` | valid_human_action | `running` | action 在节点 allowlist；actor 有权限；表单通过 Schema |
| `waiting_human` | human_sla_expired | `waiting_human` | 写超时事件、释放过期 claim、按 escalation policy 新建/改派 HumanTask；不得静默无动作 |
| `waiting_human` | human_hard_deadline_expired | `failed` | Definition 明确 hard deadline 与失败语义；保存未决任务和升级记录 |
| `running` / `waiting_human` / `queued` | cancel_requested | `cancelling` | 非终态；记录取消原因 |
| `cancelling` | all_active_nodes_terminal | `cancelled` | 所有在途节点已确认取消、超时或进入 unknown-remote 补偿路径 |
| `running` | all_required_succeeded | `completed` | 所有 required 节点成功或按显式策略跳过 |
| `running` | partial_policy_satisfied | `partially_completed` | Definition 为 `allow_partial`；达到最小成功门；失败分支完整记录 |
| `running` | unrecoverable_required_failure | `failed` | 重试耗尽且不允许 partial/manual recovery |

`completed`、`partially_completed`、`failed`、`cancelled` 为终态。`partially_completed` 不是“忽略失败”，其输出必须附带成功/失败/跳过分支清单；下游 binding 只能读取存在的输出，并显式声明是否允许缺失。

**写权限：** Workflow Runtime 单写；UI 只能发 pause/resume/cancel 或人工节点 action 命令。

## 6.5 NodeRun 状态机

| 当前状态 | 事件 | 下一状态 | 守卫 |
|---|---|---|---|
| `pending` | dependencies_satisfied | `ready` | condition 分支选中；join 条件满足；输入 binding 可解析 |
| `pending` | branch_not_selected | `skipped` | condition 结果和跳过原因已持久化 |
| `ready` | enqueue | `queued` | stale、Rights、Capability、Budget 等前置门按节点类型通过 |
| `queued` | claim | `running` | lease 成功；幂等副作用记录已创建 |
| `running` | async_submitted | `waiting_callback` | Attempt 与提交记录已落库 |
| `running` | human_prompt_created | `waiting_human` | capability mode 为 MANUAL 或节点为 human gate；责任人/表单/期限明确 |
| `waiting_human` | valid_action | `succeeded` / `failed` / `skipped` | action allowlist、权限和表单校验通过 |
| `waiting_human` | human_sla_expired | `waiting_human` | 过期 claim 释放，持久化 escalation 并按策略改派；同一超时事件幂等 |
| `waiting_human` | human_hard_deadline_expired | `failed` | 节点策略定义硬期限且没有有效 action；不得永久悬挂 |
| `running` / `waiting_callback` | retryable_failure | `retry_scheduled` | 错误类别可重试且未超过策略上限 |
| `retry_scheduled` | backoff_elapsed | `queued` | 未取消；输入仍按 stale policy 可执行 |
| `running` / `waiting_callback` | result_committed | `succeeded` | 输出 binding 校验通过；副作用已 finalize |
| 非终态 | failure_exhausted | `failed` | 重试耗尽或错误不可重试 |
| 非终态 | cancel_requested | `cancelling` | 记录原因并向下游发取消请求 |
| `cancelling` | cancel_settled | `cancelled` | 本地停止；远程状态已确认或标为 unknown 并进入补偿监控 |

`succeeded`、`failed`、`skipped`、`cancelled` 为终态。NodeRun 的 `attempt_number` 表示同一节点执行重试轮次；局部重跑创建新的 NodeRun，并写 `rerun_of_node_run_id` 与 `rerun_generation`，不得把旧终态复活。

**写权限：** Workflow Runtime 单写；handler 通过受限完成/失败 API 提交结果，不能直接改状态。

## 6.6 GenerationTask 状态机

GenerationTask 表示“基于一个固定 GenerationSpecRevision 生成 N 个候选”的业务意图。候选槽由 `candidate_index = 0..N-1` 固定。

| 当前状态 | 事件 | 下一状态 | 守卫 |
|---|---|---|---|
| `created` | begin_candidate_prefilter | `prefiltering` | Spec、输入 revision 闭包、intended-use、Catalog/Health/Quota/RoutePolicy revision 固定；尚无 Rights/预算/plan/Attempt |
| `prefiltering` | candidates_prefiltered | `rights_checking` | 创建不可变 CandidatePrefilterSnapshot ID/hash，至少一个候选；快照固定逐候选静态能力、健康、配额和淘汰证据 |
| `prefiltering` | no_prefilter_candidate | `prefilter_blocked` | 创建允许空候选的 CandidatePrefilterSnapshot 和机器可读 blocker；无 Rights snapshot、预算、plan 或 Attempt |
| `prefilter_blocked` | prefilter_inputs_changed | `prefiltering` | Catalog/Health/Quota/RoutePolicy 有可审计变化；旧预筛快照不覆盖 |
| `prefilter_blocked` | abandon | `failed` | 无人工/其他恢复路径或操作者终止 |
| `rights_checking` | rights_allowed | `routing` | 新 RightsGateSnapshot 为 `allowed`、未过期，hash/intended-use hash 已固定 |
| `rights_checking` | rights_blocked | `rights_blocked` | 保存 blocked snapshot 和逐项 finding；不得开始路由/预算/Provider 调用 |
| `rights_checking` | rights_manual_review | `rights_review` | 保存 manual_review snapshot，创建 HumanTask，并令所属 NodeRun `waiting_human` |
| `rights_review` | authorized_rights_action | `rights_checking` | HumanTask action 有效；基于新证据/批准范围重新求值并创建新 snapshot |
| `rights_review` | review_sla_expired | `rights_review` | 释放过期 claim、持久化升级并改派；不把超时当作 rights allowed |
| `rights_review` | review_hard_deadline_expired | `failed` | workflow policy 明确硬期限；保留未决 snapshot/HumanTask |
| `rights_blocked` | rights_or_use_changed | `rights_checking` | 新 rights/consent/provider policy revision 或收紧后的 intended use 已固定 |
| `rights_blocked` / `rights_review` | abandon | `failed` | 获授权终止；保留 snapshot/HumanTask |
| `routing` | no_eligible_route | `routing_blocked` | 保存逐候选淘汰理由；无 Provider plan、无 reservation、无 Attempt |
| `routing_blocked` | route_inputs_changed | `routing` | Catalog/Health/Quota/Policy 或 intended use 有可审计变化，重新解析 |
| `routing_blocked` | abandon | `failed` | 无人工/其他恢复路径或操作者终止 |
| `routing` | budget_denied | `budget_blocked` | 已保存 estimate 和拒绝原因；未提交 Provider |
| `routing` | budget_approval_required | `budget_review` | 创建 Budget HumanTask；所属 NodeRun `waiting_human`；不得创建可执行 plan |
| `budget_review` | budget_approved | `routing` | 重新读取价格/额度并原子创建新 held reservation；旧 estimate 不直接放行 |
| `budget_review` | budget_rejected | `budget_blocked` / `failed` | 保存人工决定；按 workflow recovery policy 处理 |
| `budget_review` | review_sla_expired | `budget_review` | 释放过期 claim、升级/改派；不创建 reservation/plan |
| `budget_review` | review_hard_deadline_expired | `failed` | workflow policy 明确硬期限；保留 estimate 与人工任务审计 |
| `routing` | plans_pinned_and_reserved | `ready` | 每槽 plan 固定未过期 `allowed` Rights snapshot；budget decision=`allow` 且非空 reservation 在 pin 时为 `held` |
| `budget_blocked` | budget_adjusted / reestimate | `routing` | 旧 estimate/reservation 不复用；基于当前价格、配额和候选数创建新 estimate |
| `budget_blocked` | abandon | `failed` | 操作者终止或恢复期限耗尽 |
| `ready` | first_attempt_started | `running` | 每槽业务幂等键唯一 |
| `running` | all_slots_succeeded | `completed` | 每槽至少一个成功 Attempt，所有输出已 finalize |
| `running` | minimum_slots_succeeded | `partially_completed` | 策略允许 partial；失败槽与费用完整记录 |
| `running` / `ready` | unrecoverable | `failed` | 重试/fallback 用尽且不满足 partial |
| 非终态 | cancel_settled | `cancelled` | 所有在途 Attempt 已进入终态或补偿监控 |

`prefilter_blocked`、`rights_review`、`routing_blocked`、`budget_blocked`、`budget_review` 都是有明确恢复命令的等待状态，不是空转字符串。Schema 要求自 `rights_checking` 起的状态携带 CandidatePrefilterSnapshot ID/hash，blocked 状态携带机器可读 blocker/recovery actions，review 状态另须携带 HumanTask ID。补充预算或调整候选数后必须重新估算并新建 reservation，不能复用过期估算。任何等待路径选择放弃都收敛到 `failed`。`completed` 只表示得到候选，不表示候选 QC 或审核通过。

**写权限：** Generation Orchestrator 单写。

## 6.7 ProviderAttempt（领域章 GenerationAttempt）状态机

本章和 Schema 使用 `ProviderAttempt` 强调它是一次具体执行；它与领域模型中的 `GenerationAttempt` 是同一实体，不再额外创建第二层“ModelRun”。

| 当前状态 | 事件 | 下一状态 | 守卫 |
|---|---|---|---|
| `created` | begin_submit | `submitting` | plan 已 pin；allowed Rights snapshot 未过期且 intended-use hash 相同；reservation held；ProviderRequestSnapshot ID/hash 已固定；提交幂等行已提交 |
| `submitting` | provider_ack | `submitted` | 保存 provider job ID；同 Provider 内 operation ID 唯一 |
| `submitted` | provider_running | `running` | 回调签名有效且状态不倒退 |
| `submitted` / `running` | output_announced | `output_pending_finalize` | 远程结果成功；输出仍在 staged/quarantine 区 |
| `output_pending_finalize` | all_outputs_finalized | `succeeded` | hash、大小、类型、媒体探测和血缘均校验通过 |
| 非终态 | terminal_provider_error | `failed` | 错误分类已规范化；实际用量尽力结算 |
| 非终态 | deadline_elapsed | `timed_out` | deadline 到达；后续迟到回调不得自动覆盖终态 |
| 非终态 | cancel_requested | `cancelling` | Adapter 支持则发送取消；记录请求结果 |
| `cancelling` | provider_cancelled | `cancelled` | Provider 确认或本地确定无外部副作用 |
| `submitting` / `cancelling` | remote_state_uncertain | `unknown_remote_state` | 网络中断且无法证明是否已提交/取消；启动查询与对账 |
| `unknown_remote_state` | reconciliation_found_job | `submitted` / `running` | 按 submission key 查询到同一远程 job，并以远程单向状态为准 |
| `unknown_remote_state` | reconciliation_found_output | `output_pending_finalize` | 远程输出身份可验证；仍需 staged/finalize |
| `unknown_remote_state` | reconciliation_confirmed_failure | `failed` | Provider 明确确认失败且保存用量/错误证据 |
| `unknown_remote_state` | reconciliation_confirmed_cancel | `cancelled` | Provider 明确确认未执行或已取消 |

所有终态都保留。`unknown_remote_state` 不是终态：它持续低频查询和账单对账，并创建人工处置告警；对账 SLA 耗尽也不伪造失败/取消。对该状态禁止盲目重提；只有获授权操作者明确接受重复计费风险时，才可创建新 Attempt，旧 Attempt 仍保留并继续对账。

**写权限：** Provider Gateway/Adapter 只能经 Attempt Service 写；Callback Consumer 只能提交已验证事件。

## 6.8 Asset ingest 与 QC 状态

### 字节可用性

UploadIntent 状态为：

```text
initiated → uploaded → finalizing → finalized
initiated/uploaded → expired / aborted
```

`quarantined` 不是 UploadIntent 状态。验证失败时 intent 进入 `aborted`（或到期 `expired`），同时独立创建 ObjectQuarantine/Restriction 记录保存隔离对象、原因和处置；事后安全事件也只改变 Asset 可用性投影，不改写 intent。只有 `finalized` 才要求同时存在 `asset_version_id/finalized_at` 并创建可引用的 AssetVersion；所有非 finalized intent 都禁止携带这两个字段。AssetVersion Schema 中 `finalized` 恒为 `true`。物理 blob 去重不合并不同血缘的 AssetVersion。

### QC 投影

QC 的事实来自不可变 QualityReport/Evidence；下列状态只是聚合投影：

| 状态 | 含义 | 进入守卫 |
|---|---|---|
| `not_started` | 尚无 required 检查 | AssetVersion 已 finalized |
| `running` | 至少一项 required 检查在运行 | 检查策略版本固定 |
| `passed` | required 检查全通过 | 无 error finding |
| `passed_with_warning` | required 检查通过但有 warning | warning 均有证据 |
| `failed` | 至少一项 required 检查失败 | hard rule 或阈值失败 |
| `inconclusive` | 证据不足或 analyzer 不可用 | 不得等价 `passed` |
| `waived` | 获授权主体接受特定失败 | Waiver 限定 asset、报告版本、范围和期限 |

新 QualityReport 不覆盖旧报告；投影按当前项目策略版本重新计算。Analyzer 只能写证据，Quality Decision Engine 只能写自动决定，Reviewer 才能写 waiver/批准。

## 6.9 ReviewDecision 状态

Review 是独立 case；Decision 是不可变结果。case 可处于 `pending → in_review → decided`，也可进入 `cancelled`。case 取消不创建 ReviewDecision。ReviewDecision 的 action 型枚举与质量 Schema 一致：

- `approve`：批准指定 AssetVersion 在限定用途使用；
- `reject`：不可采用；
- `request_repair`：创建修复任务，不修改原资产；
- `request_regeneration`：创建新的 GenerationTask；
- `waive`：接受明确列出的偏差或质量失败，必须携带限定范围的 Waiver。

如审核认为权威事实或导演意图需要变化，另行提交 `CanonicalChangeProposal`；它不是 ReviewDecision 的隐藏枚举，也不直接改旧 Revision。守卫：决策必须固定 QualityReport/AutomatedDecision 版本、AssetVersion、输入 Revision 与 reviewer；自动 `pass` 不能直接生成 `approve`。新决策通过 `supersedes_id` 取代旧决策，旧记录不可变。

**写权限：** Review Service；人工 reviewer、获授权确定性规则或审计过的批量策略是 actor。LLM 只能提供建议。

## 6.10 TimelineVersion 与 Release

### TimelineVersion

| 当前状态 | 事件 | 下一状态 | 守卫 |
|---|---|---|---|
| `draft` | freeze | `frozen` | clips 均精确引用 finalized AssetVersion；轨道/时码校验通过 |
| `draft` | abandon | `superseded` | 保留审计 |
| `frozen` | newer_version_selected | `superseded` | 新版本另有 ID；旧版本不变 |

只有 `draft` 可编辑；任何剪辑变更创建新的 TimelineVersion 或在 draft 内按乐观锁保存。Release 只能引用 `frozen`。

### Release

| 当前状态 | 事件 | 下一状态 | 守卫 |
|---|---|---|---|
| `draft` | validate | `validating` | 只冻结 PreRenderEvaluationInput（TimelineVersion、输入闭包、render profile 和评估策略 hash）；此时不得创建 RenderInputManifest/ReleaseManifest |
| `validating` | pre_render_eligibility_failed | `blocked` | 保存输入资产 Rights/QC/Review/stale/平台规格失败清单；这不是最终 ReleaseGate |
| `blocked` | revalidate | `validating` | 产生新 gate report；不覆盖旧证据 |
| `validating` | pre_render_eligibility_passed | `ready` | 在同一事务确认 render-use RightsGate=`allowed` 且未过期、全部 availability=`available`、Review/waiver/stale/平台条件有效，然后创建不可变 RenderInputManifest；尚未产生整集导出 QC/ReleaseGate |
| `ready` | approve_release | `approved` | 人工发布批准者有权限；批准固定 RenderInputManifest ID/hash、Rights/availability/Review/waiver hash 集 |
| `approved` | render | `rendering` | 开始副作用前即时重读 Rights 状态/hash/expiry、availability revision/hash/status、Review/waiver validity；均与批准及 RenderInputManifest 相同且当前有效；输出参数和 render 幂等键固定 |
| `rendering` | render_succeeded | `rendered` | export AssetVersion finalize；整集 QC/Rights/ReleaseGate 完成后创建 ReleaseManifest |
| `rendered` | publish | `publishing` | ReleaseManifest 已固定 export、最终 QC、Rights snapshot、ReleaseGate、目标和 manifest hash；追加 PublishAttempt |
| `publishing` | selected_publish_attempt_succeeded | `published` | PublishAttempt 为 `published`，远程 publication ID 存在，attempt manifest hash 与 ReleaseManifest 相同 |
| `rendering` | render_error | `failed` | 保存 RenderAttempt；当前 ReleaseCandidate 不再恢复 |
| `publishing` | abandon_after_definitive_failures | `failed` | 所有 PublishAttempt 均为明确终态且操作者放弃；unknown 状态禁止此转换 |
| `published` | revoke | `revoked` | 获授权；记录平台下架结果，历史 Release 保留 |

`PreRenderEvaluationInput` 只是求值输入，不是渲染授权。`RenderInputManifest` 只有在 pre-render eligibility 成功的事务中才创建，并固定 Timeline/输入闭包/render profile 及当时有效的 Rights、availability、Review/waiver 证据；`ReleaseManifest` 只能在 render 与最终 QC/Rights Gate 后创建，固定 export AssetVersion、ReleaseGate、发布目标和最终 hash。三者不得复用同一 ID/hash 或互相改名冒充。

`validating → ready` 仅是 **pre-render eligibility**，检查输入闭包是否值得开始昂贵渲染，不能命名或存储为 `ReleaseGate`。真正的 `ReleaseGate` 只能在 export AssetVersion finalize 且整集 Release QC 完成后创建，必须固定 `export_asset_version_id`、`quality_report_id`、`release_gate_id` 和独立的 `gate_input_closure_hash`。ReleaseManifest 随后固定 `release_gate_hash` 与自身 `manifest_hash`，因此不存在 Gate 引用后创建 Manifest 的循环。publish 命令再次比较 Gate/Manifest 及即时 preflight 的全部 hash，任何不一致均回到新 ReleaseCandidate，而不是沿用旧 gate。

### PublishAttempt

发布副作用是追加式 Attempt，不把远程调用细节写回 ReleaseManifest：

| 当前状态 | 事件 | 下一状态 | 守卫 |
|---|---|---|---|
| `created` | begin_submit | `submitting` | 紧邻外部调用的 publication preflight=`passed`；ReleaseManifest/Gate 均未过期且 hash 当前，全部 availability=`available`、Rights=`allowed`、waiver/ReviewDecision 当前有效；固定 policy revision、上述快照 hash、目标账号和 submission key |
| `created` | publication_preflight_failed | `failed` | 保存 `publication_preflight_result=failed`、各当前输入 hash 和失败原因；证明尚未发出外部副作用，禁止使用 submission key 重发 |
| `created` | gate_invalidated | `failed` | Gate/Manifest 在 submit 前失效；证明尚未发出外部副作用并创建新 ReleaseCandidate |
| `submitting` | platform_ack | `submitted` | 保存 remote operation/publication ID |
| `submitting` / `submitted` | gate_invalidated | `cancelling` | 不假设尚未发布；幂等请求取消/撤稿并启动按 submission key/remote ID 对账 |
| `submitting` / `cancelling` | remote_state_uncertain | `unknown_remote_state` | 无法证明是否发布/取消，立即启动按 submission key 对账 |
| `submitted` | publication_visible | `published` | 远程 ID、目标账号与 manifest hash 可核对 |
| 非终态 | definitive_error | `failed` | 平台明确未发布或返回不可恢复失败 |
| 非终态 | cancel_requested | `cancelling` | 幂等发送取消/删除草稿请求 |
| `cancelling` | cancel_confirmed | `cancelled` | 平台明确确认 |
| `unknown_remote_state` | reconcile_found_submission | `submitted` | 找到同 submission key 的远程操作 |
| `unknown_remote_state` | reconcile_found_publication | `published` | 找到目标账号下 hash/metadata 匹配的发布 |
| `unknown_remote_state` | reconcile_confirmed_absent_or_failed | `failed` / `cancelled` | 平台查询或人工证据能证明未发布 |

`publication_preflight_result`、policy revision、availability/Rights/waiver/Review/Gate hash 集是 PublishAttempt 的必需审计输入；Schema 对所有已进入外部副作用的状态强制结果为 `passed`。`unknown_remote_state` 不是失败，也不是允许重发的依据。它持续查询、账单/平台对账并触发人工处置；只有确认旧 Attempt 未发布或已失败后才可创建 `attempt_ordinal + 1` 的新 PublishAttempt。重传同一次 submit 必须复用原 submission key。

`failed` 是 Release 终态。渲染失败需创建新 ReleaseCandidate/Release；仅 PublishAttempt 明确失败时，可在相同未变 ReleaseManifest 下追加新 PublishAttempt。若 manifest/目标变化则必须创建新 ReleaseCandidate。`published` 不意味着源资产状态改变。重新剪辑、重新导出或修订元数据同样创建新 ReleaseCandidate/Release，不原地重写已发布闭包。

**写权限：** Timeline Service 单写 TimelineVersion；Release Service 单写 Release；发布批准者只提交 command。

## 6.11 跨状态轴守卫矩阵

| 动作 | 必须满足 | 明确不代表 |
|---|---|---|
| 提交真实 Provider | 内容/导演输入固定；stale、Rights、Capability、Budget 门通过 | 内容会被批准 |
| Finalize AssetVersion | hash/媒体/血缘完整 | QC 通过 |
| 人工批准候选 | Asset finalized；required evidence 完整；权限有效 | 已进入 Timeline |
| Freeze Timeline | 所有 clip 精确引用；轨道合法 | 可发布 |
| Approve Release | 冻结闭包的 Rights/QC/Review/stale 门通过 | 平台已经接收 |

## 6.12 验收检查

- [ ] UI 能同时展示“ShotPlanRevision 已批准、GenerationTask 失败、无可用候选”，不会压成单一状态。
- [ ] 重复/乱序回调不能把 `failed/cancelled/timed_out` 倒退到 `running` 或静默创建资产。
- [ ] Workflow partial completion 明确列出失败分支，下游不能读取不存在的 output。
- [ ] 局部重跑创建新 NodeRun 并保留 `rerun_of`，旧终态不变。
- [ ] Attempt 远程成功但对象尚未 finalize 时仍不可审核或进时间线。
- [ ] 自动 QC `passed` 不自动创建 ReviewDecision `approve`。
- [ ] Timeline 与 Release 只引用精确版本，任何重新剪辑/重发均创建新版本记录。
- [ ] 每条迁移均能定位 actor、守卫证据、幂等 command 和 trace。
