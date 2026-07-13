# 7. Workflow Runtime 合同

## 7.1 对象关系与所有权

```text
WorkflowDefinition@version
        │ materialize
        ▼
WorkflowRun ── 1..* NodeRun
                    │ generation handler
                    ▼
              GenerationTask ── 1..N candidate slots
                    │
                    ├── RightsGateSnapshot (allowed, unexpired)
                    └── ResolvedExecutionPlan (budget allow + held reservation)
                                      │ compile exact request
                                      ▼
                             ProviderRequestSnapshot
                                      │ 1..* execution tries
                                      ▼
                                ProviderAttempt
                                      │ 0..* finalized outputs
                                      ▼
                                 AssetVersion
```

- `WorkflowDefinition` 是版本化、发布后不可变的 DAG 模板。
- `WorkflowRun` 固定 Definition 版本和初始输入快照，不追随 head。
- `NodeRun` 是节点的一次具体执行；fan-out 项、局部重跑均有独立 NodeRun ID。
- `GenerationTask` 固定一个 GenerationSpecRevision，表示生成 N 个候选的业务意图。
- `RightsGateSnapshot` 对精确输入、Provider policy 与 intended use 求值；只有 `allowed` 且未过期可进入可执行 plan。
- `ProviderRequestSnapshot` 是 Adapter 生成的加密、不可变请求合同，保存业务 payload hash、解析输入和脱敏预览；它不是媒体 AssetVersion。
- `ProviderAttempt`（领域章的 GenerationAttempt）表示一次可能收费/产生随机输出的 Provider 副作用，并必须固定 plan、request snapshot 和 Rights snapshot 的 ID/hash。
- `AssetVersion` 只有在对象 finalize 后存在；成功 Attempt 可产生零到多个 AssetVersion。

服务所有权：Workflow Runtime 拥有 Definition/Run/NodeRun 及普通/预算 HumanTask；Generation Orchestrator 拥有 GenerationTask；Provider Routing Service 拥有 CandidatePrefilterSnapshot 和 ResolvedExecutionPlan；Rights Service 拥有 RightsGateSnapshot/RightsHumanTask；Provider Gateway 拥有 Attempt 和 ProviderRequestSnapshot；Asset Registry 拥有 AssetVersion。跨模块通过受限 command 和 outbox 事件连接，不跨模块写表。

GenerationTask 进入 Provider 前严格按 `created → prefiltering → rights_checking → routing/预算 → ready → running` 推进，对应 `只读 Capability/Health/Quota 候选预筛 → 对候选执行 RightsGate → 最终 Route/Cost Estimate/Budget → immutable plan → request snapshot → submit`。`CandidatePrefilterSnapshot` 的 ID/hash 从 `rights_checking` 起成为必需运行证据；预筛只确定需要评估哪些 Provider policy，不产生 plan、不是授权门。预筛无候选进入 `prefilter_blocked`，Rights 后无最终路由才进入 `routing_blocked`；其他 `blocked/manual_review/approval_required` 也先进入第 6 章定义的可恢复状态，不得创建半有效 ResolvedExecutionPlan。

## 7.2 WorkflowDefinition 发布校验

Definition 发布前必须通过确定性校验：

1. `id + version` 唯一，`graph_hash` 由规范化 Definition 计算；
2. node ID 在 Definition 内唯一；所有 `depends_on` 和 condition target 存在；
3. DAG 无环；只有显式 retry 形成运行时重入，不在图中画回边；
4. 每个 required input binding 可由 workflow input、依赖输出、fan-out item 或 constant 解析；
5. dependency output 只能读取祖先节点；JSON Pointer 和目标类型可验证；
6. condition 使用受限、无副作用的 `cel_v1`，禁止网络、时钟和随机数；
7. fan-out 有有界 `max_parallelism`；join 的 minimum 不超过可能分支数或在运行时可证明；
8. human gate 有 form schema、允许动作、claim timeout 和责任角色；
9. 每个节点有 timeout、cancel、retry、stale 和 exhausted 策略；
10. `UNAVAILABLE` 的 required 节点必须在发布时阻止 Definition，或存在明确 manual/skip 分支。

Definition 升级创建新版本；在途 Run 继续使用旧版本。不得在 Run 中“热替换”节点 handler 或路由策略。

## 7.3 节点类型

| kind | 作用 | 运行时语义 |
|---|---|---|
| `task` | 调用确定性 handler、Worker 或生成服务 | 可同步完成，也可进入 `waiting_callback` |
| `condition` | 选择分支 | 对固定输入只计算一次并保存表达式、输入 hash、结果；未选分支 `skipped` |
| `fan_out` | 将集合展开为多个 NodeRun | item key/index 固定；同一集合重放不得重复创建子运行 |
| `join` | 汇合并行分支 | 支持 `all_terminal`、`all_successful`、`any_successful`、`minimum_successful` |
| `human_gate` | 暂停并等待获授权动作 | 生成 HumanTask；claim 和 action 均幂等、可审计 |

### Condition

Condition 只能读取已绑定输入。结果记录：Definition 版本、表达式 hash、input snapshot hash、布尔结果、选中 target。局部重跑上游后若输入变化，必须创建新的 condition NodeRun，不能更改旧结果。

### Fan-out / join

fan-out item identity 使用稳定业务 key；若源集合只有数组位置，则 materialize 时同时保存规范化 item hash，避免重排误认。每个子 NodeRun 的唯一约束为：

```text
(workflow_run_id, node_definition_id, fanout_item_key, rerun_generation)
```

join 在同一事务读取已提交的分支终态并写入一次 join result。`any_successful` 或 `minimum_successful` 达标后是否取消剩余分支由 `cancel_remaining_after_satisfied` 决定；取消失败不会回滚已满足的 join，但必须继续成本/迟到结果对账。

`all_terminal` 只表示分支都结束，不表示都成功。下游需要成功资产时必须读取带状态的聚合输出，而不是假定数组成员都有效。

## 7.4 Input/Output Binding 与快照

Binding 在 NodeRun 入队前解析，解析结果保存为不可变 `InputSnapshot`：

- `workflow_input`：Run 创建时固定的输入；
- `dependency_output`：精确 NodeRun 的已提交输出；
- `fanout_item`：当前展开项；
- `constant`：Definition 中的规范化常量。

Binding 目标和来源使用 RFC 6901 JSON Pointer。核心输入以 `(entity_type, logical_id, revision_id, content_hash)` 引用，禁止 `latest`。输出先由 handler schema 校验，再原子提交 NodeRun `succeeded` 与 outbox；大型输出只保存 AssetVersion/快照引用，不把媒体塞入 job payload。

optional binding 缺失时写显式 `null/not_present` 或省略约定值，取决于输出 schema；不得在 handler 内隐式查 head。required binding 缺失直接失败为 `validation`，不会调用 Provider。

## 7.5 Run materialization 与调度

创建 WorkflowRun 的事务顺序：

1. 根据客户端 request key 获取或创建唯一 Run；
2. 固定 Definition 版本、输入 Revision 闭包和 `snapshot_hash`；
3. 创建无依赖的初始 NodeRun；
4. 写 `workflow_run.created` outbox；
5. 事务提交后由 dispatcher 投递队列。

调度采用数据库事实源 + 至少一次队列。队列消息只含 NodeRun ID 和 trace context；Worker claim 使用 lease/compare-and-swap。lease 过期可重新投递，但副作用仍受业务幂等行保护。进程内内存不得作为节点完成事实。

## 7.6 人工暂停、claim 与恢复

human gate 或 MANUAL capability 创建 HumanTask，至少包含：

- NodeRun、固定输入和预览资产；
- form schema/version、allowed actions；
- required role/assignee、`claim_timeout_seconds`、`sla_seconds`、`hard_deadline_seconds` 和 `escalation_policy_revision_id`；
- 对每个 action 的下游语义。

Definition 中的 `humanGateSpec` 只定义模板；运行时必须另建不可变身份的 HumanTask 记录。该记录固定 owner、输入 snapshot hash、状态、claim/SLA/hard-deadline/escalation 字段和最终 action。普通 gate、manual capability 与 Budget review 使用 Workflow Runtime 的通用 HumanTask 合同；Rights review 因含权利专用 action/重新求值语义，使用 Rights Service 的 RightsHumanTask 合同。NodeRun=`waiting_human` 与 GenerationTask=`budget_review` 都必须通过外键引用对应运行时任务，任务再外键引用其 owner；不能只依赖 Definition 字段或接受孤儿引用。

`claim` 只授予短期处理权，不改变业务结果。`act` 请求携带 HumanTask version 和 command id；服务校验权限、claim、表单和当前 NodeRun 状态，在同一事务写 HumanAction、NodeRun 终态和 outbox。重复 act 返回原结果；不同动作竞争时只有首个满足乐观锁的命令成功。

SLA 到期不是默认批准/拒绝。调度器以幂等 `human_sla_expired` 事件释放过期 claim、记录 escalation 并按 policy 改派或升级，业务状态仍保持等待。每个 required HumanTask 还必须有 Definition 固定的 hard deadline；到期且无有效 action 时原子清除 claim、写 `deadline_expired_at`、禁止 action 字段并令任务进入 `deadline_expired`，再以 `human_hard_deadline_expired` 将对应 NodeRun/GenerationTask 收敛为 `failed`，WorkflowRun 按 completion policy 进入 `failed` 或 `partially_completed`。若业务确实允许无限等待，必须把它声明为非 required/可取消流程，而不能遗漏期限。

WorkflowRun 进入 `waiting_human` 只是聚合投影。任何可运行的并行分支仍可继续；当 required 人工节点获有效 action 后自动恢复 `running`，无需手工重启进程。

## 7.7 Partial completion

partial 必须由 Definition 显式声明，不能由异常处理临时决定。实施时定义：

- 哪些节点 `required_for_run`；
- fan-out/join 最小成功数；
- 允许的失败类别；
- 下游输出如何携带 succeeded/failed/skipped 清单；
- 是否允许进入人工审核、Timeline 或 Release。

`partially_completed` 是 WorkflowRun/GenerationTask 的终态，但不自动通过下游发布门。Release 默认要求所引用的全部资产成功、finalized 且通过 required QC；未引用的候选失败可以保留为审计记录。

Schema 对 `CandidateSlot(status=succeeded)` 强制至少一个 Attempt ID 和一个 AssetVersion ID。以下仍由领域 validator/数据库唯一约束执行：candidate index 连续且等于 `0..N-1`、Attempt 必须属于同一 task/index、AssetVersion 必须来源于列出的成功 Attempt、内容 hash 去重不能改变血缘。

## 7.8 Retry、regenerate 与 fallback

| 动作 | 新建什么 | 固定不变 | 允许变化 | 典型触发 |
|---|---|---|---|---|
| transport retry | 不新建 Attempt | submission key、Provider job、请求字节 | HTTP 连接/查询次数 | GET 超时、ACK 丢失但可按 key 查询 |
| execution retry | 新 `ProviderAttempt(kind=retry)` | GenerationTask、Spec、candidate index、Provider/model plan | attempt ordinal、可能的新随机输出和费用 | Provider transient、rate limit、超时且已完成对账 |
| fallback | 新 ResolvedExecutionPlan + 新 `ProviderAttempt(kind=fallback)` | GenerationTask、Spec、candidate index | Provider/model/Adapter；必须记录 reason | circuit open、quota、策略允许的 provider failure |
| regenerate | 新 GenerationTask；通常新 Spec Revision | 来源决策和血缘 | 提示/约束/seed/候选意图；也可显式“同 Spec 再抽样” | 质量不合格、导演要求新创意 |
| local node rerun | 新 NodeRun，`rerun_of` 指向旧运行 | Definition 版本（默认） | 输入快照、rerun generation | 修复上游或手动重跑局部 DAG |

只要调用可能再次计费、产生随机产物或创建远程 job，就不是 transport retry。`retryable=true` 只是允许重试，不要求自动重试；预算、attempt 上限、deadline 与 cancellation 优先。

fallback 不得在同一 Attempt 内静默改 Provider。新 plan 记录旧 plan、健康快照、fallback 原因和新的成本预留；旧 Attempt 保持原终态。

regenerate 是新的创作/生产意图。即使复用同一 Spec，也必须有新的 task ID、regeneration reason/nonce，从而不被幂等去重吞掉。

## 7.9 N 候选幂等键

实现统一使用 UTF-8、字段长度前缀或 canonical JSON 编码后 SHA-256；以下竖线仅用于说明，不直接拼接未转义用户字符串。

```text
workflow_run_key = sha256(
  "workflow-run:v1" | project_id | definition_id | definition_version | client_request_key
)

node_run_key = sha256(
  "node-run:v1" | workflow_run_id | node_definition_id |
  fanout_item_key_or_none | input_snapshot_hash | rerun_generation
)

generation_task_key = sha256(
  "generation-task:v1" | node_run_id | generation_spec_revision_id |
  generation_spec_hash | regeneration_nonce_or_zero
)

candidate_business_key[i] = sha256(
  "generation-candidate:v1" | project_id | generation_task_id |
  generation_spec_hash | candidate_index=i
), 0 <= i < N

provider_submission_key = sha256(
  "provider-submit:v1" | candidate_business_key[i] |
  resolved_execution_plan_id | attempt_ordinal
)
```

约束：

- 同一 task 的 candidate index 唯一且连续 `0..N-1`；
- execution retry/fallback 保持 candidate business key，但因 plan/ordinal 创建新的 provider submission key；
- 对 Provider 的一次 submit 重传必须复用同一 provider submission key；
- 新 regenerate task 产生新的 candidate business key；
- 数据库唯一约束至少覆盖 Run key、Node key、Task key、`(task_id, candidate_index, attempt_ordinal)` 和 `(provider_id, provider_submission_key)`；
- Provider 不支持幂等键时，在调用前持久化 `submitting`，超时进入 `unknown_remote_state` 并先查询/人工对账，不能直接盲重试。

## 7.10 Timeout 与 cancellation

timeout 包含：队列等待 SLA、handler execution deadline、Provider deadline、callback deadline 和 human SLA；只有 execution/provider deadline 直接推进 Attempt/Node 的超时路径。超时不证明远程任务不存在。

取消采用协作式流程：

1. Run/Node 写 `cancelling` 和取消原因；
2. 停止调度尚未开始的后继节点；
3. 对在途 Provider 调用幂等发送 cancel；
4. 在 grace period 内查询最终状态；
5. 不能确认时写 `unknown_remote_state`，继续 reconciliation；
6. 迟到产物可 finalize 到隔离候选并计费，但不能自动选中或令已取消 Run 成功。

取消不删除已产生的费用、Attempt、Asset 或证据。

## 7.11 局部重跑与 stale input

局部重跑先计算受影响子图。新 NodeRun 精确记录旧 NodeRun、原因、操作者和新的 input snapshot。默认复用未 stale 且输出 hash 满足依赖的上游结果；不得仅按“节点曾成功”复用。

执行前比较：

```text
observed_input_hash（NodeRun 固定快照）
vs
current_input_hash（当前选中权威 Revision 闭包）
```

不相等则 `stale_input=true`，按节点策略处理：

- `block`：不入队，要求重新编译/新 Run；
- `require_decision`：创建人工任务，选择重跑或接受 pinned snapshot；
- `allow_pinned_snapshot`：继续旧快照，并留下接受原因/策略版本。

在途 Attempt 永远继续绑定原 Spec 和原输入。新 head 不能注入旧 Attempt。Release Gate 默认阻止 required dependency stale，除非 waiver 精确限定版本闭包。

## 7.12 At-least-once、Inbox 与 Outbox

系统不宣称端到端 exactly-once。收敛规则如下：

### Callback Inbox

1. 在读取业务 payload 前验证签名、时间窗和防重放 token；
2. 用 `(provider_id, delivery_id)` 唯一插入 Inbox；没有 delivery ID 时使用经审计的 provider job ID + event type + payload hash；
3. 重复投递标记 `duplicate` 并返回 2xx，不重复业务副作用；
4. 在单库事务锁定 Attempt，验证单向迁移，应用事件并写 outbox；
5. 无效签名只保存最小安全元数据并 `rejected`；解析失败进入 dead letter，禁止日志落完整 secret/URL；
6. 旧 Attempt 的迟到回调可附加审计或产物隔离记录，不能覆盖新 fallback Attempt 的选择结果。

### Transactional Outbox

领域状态和 event outbox 同事务提交。Dispatcher 至少一次发送；消费者以 event ID/业务键去重。Outbox `delivered` 只表示目标确认接收，不表示下游业务完成。超过上限进入 dead letter 并告警，保留可重放入口。

## 7.13 对象上传与 finalize 接口边界

数据库与对象存储不做分布式事务。采用 staged → finalized 协议：

### 1. 创建 UploadIntent

```http
POST /v1/upload-intents
Idempotency-Key: <owner-scoped-key>

{
  "owner_type": "provider_attempt",
  "owner_id": "pat_...",
  "expected_content_type": "video/mp4",
  "expected_size_bytes": 18420311,
  "expected_content_hash": "sha256:..."
}
```

服务端分配不可猜测的 staging object key 和短期签名上传 URL。客户端无权选择 finalized key，也无权把对象标为 AssetVersion。

### 2. 上传对象

客户端/Adapter 仅向 staging prefix PUT。Bucket policy 禁止覆盖同 key、公开访问和任意 metadata。完成后对象仍不可用于 Timeline/Review。

### 3. 请求 finalize

```http
POST /v1/upload-intents/{id}/finalize
Idempotency-Key: <upload-intent-id>

{
  "observed_etag": "...",
  "observed_size_bytes": 18420311
}
```

Finalize Worker 执行 HEAD/下载流 hash、MIME 嗅探、ffprobe/图片解析、恶意内容扫描和 owner/Attempt 守卫。不能把客户端声明的 hash 当成校验结果。

### 4. 原子登记

校验成功后先把 UploadIntent CAS 为 `finalizing` 并写入已验证 metadata/hash；此时仍不创建 AssetVersion。Finalize Worker 使用不可覆盖的目标键执行 conditional copy（或服务端受控 promote），随后对目标对象再次 HEAD/必要时抽样读取，确认目标 key、大小、hash/etag 和可用性。

只有 finalized 区对象确认可读后，才在一个数据库事务中：

- 创建不可变 AssetVersion、血缘和物理 blob 引用；
- 将 UploadIntent 置 `finalized`，同一事务写入必填 `asset_version_id/finalized_at`；
- 若 owner 是 Attempt，关联 candidate slot，并在所有输出完成时推进 Attempt；
- 写 outbox。

物理 blob 可按 hash 去重，但不同来源/授权/血缘仍保留不同 AssetVersion。staging 清理发生在上述事务成功之后；若目标 copy 成功而数据库事务失败，UploadIntent 保持 `finalizing`，重试通过目标 key/hash 幂等收敛，orphan sweeper 在保留期后处理。任何 blob 尚未确认时都不得创建可引用 AssetVersion。

校验失败时 UploadIntent 进入 `aborted` 并记录安全错误；需要保留可疑对象时另建 ObjectQuarantine/Restriction 记录。`quarantined` 不属于 UploadIntent 枚举。所有非 `finalized` intent 均禁止出现 `asset_version_id/finalized_at`。对象存在而数据库无意图、意图过期或事务失败时由 orphan sweeper 按保留期清理；不得用列举对象反推业务成功。

## 7.14 渲染清单、发布清单与追加式发布

发布链使用两个不可变清单：

```text
Frozen TimelineVersion
→ RenderInputManifest（输入闭包 + render profile）
→ RenderAttempt
→ finalized export AssetVersion
→ final QC + release RightsGate + ReleaseGate
→ ReleaseManifest（export + gate + target + final hash）
→ PublishAttempt 1..N
```

PreRenderEvaluationInput 求值通过后才可创建 RenderInputManifest；RenderInputManifest 不包含尚未存在的 export/QC/ReleaseGate，ReleaseManifest 不允许在 render 前预创建。ReleaseGate 用独立 `gate_input_closure_hash` 固定自身输入，ReleaseManifest 再固定 Gate canonical hash 和自身 manifest hash，禁止循环引用。PublishAttempt 每次即时 preflight 并固定相同 ReleaseManifest ID/hash、Gate/Rights/availability/waiver/Review hash、目标账号、attempt ordinal 和 submission key。网络不确定进入 `unknown_remote_state` 后必须按 submission key/远程 ID 对账；不能把“未收到 ACK”解释成“未发布”并盲发。只有确认旧 Attempt 未发布或明确失败后才追加下一 Attempt。目标或 manifest 变化必须创建新 ReleaseCandidate/ReleaseManifest。

## 7.15 写入权限与接口

| 对象 | 唯一写入者 | 外部允许的命令 |
|---|---|---|
| WorkflowDefinition | Workflow Registry | validate/publish new version |
| WorkflowRun / NodeRun | Workflow Runtime | start, cancel, rerun, human action |
| 普通/预算 HumanTask | Workflow Runtime | create/claim/escalate/act/expire；预算 action 以事件交给 Generation Orchestrator |
| GenerationTask | Generation Orchestrator | request generation/regenerate/cancel |
| CandidatePrefilterSnapshot / ResolvedExecutionPlan | Provider Routing Service | prefilter/resolve；只创建不可变记录 |
| RightsGateSnapshot / Rights HumanTask | Rights Service | evaluate/claim/act/re-evaluate |
| ProviderAttempt / ProviderRequestSnapshot | Provider Gateway | compile request/submit/query/cancel；callback 经 Inbox |
| UploadIntent | Asset Ingest Service | create/finalize/abort |
| AssetVersion | Asset Registry | finalize from verified upload/manual import |
| RenderInputManifest / ReleaseManifest | Release Service | create immutable manifest at the correct phase |
| PublishAttempt | Publication Gateway | submit/query/cancel/reconcile |
| Inbox/Outbox | Delivery infrastructure | receive/dispatch/replay dead letter |

Worker 返回值不直接写终态；必须调用带 expected state、幂等键和输出 schema 的 complete/fail API。

## 7.16 验收检查

- [ ] Definition 校验能拒绝环、悬空依赖、非法 binding、无界 fan-out 和 required UNAVAILABLE 节点。
- [ ] Condition 的同一输入只产生一个固定结果；fan-out 重投递不重复创建子 NodeRun。
- [ ] join 的 `all_terminal` 与 `all_successful` 不会混淆，partial 输出携带每个分支状态。
- [ ] 人工 gate 在进程重启后仍可 claim/act/resume；竞争动作只有一个成功。
- [ ] Rights `manual_review` 与 Budget `approval_required` 都创建 HumanTask；无 eligible route/blocked/deny 都有恢复或失败闭环且未创建 Attempt。
- [ ] N 候选在回调重复、Worker 重投和 submit ACK 丢失时仍最多每槽一个逻辑结果集合。
- [ ] `succeeded` candidate slot 至少引用一个属于同 task/index 的成功 Attempt 及其 finalized AssetVersion。
- [ ] Attempt 引用独立 ProviderRequestSnapshot ID/hash；请求快照不会伪装成 AssetVersion。
- [ ] retry、fallback、regenerate 生成正确的新实体和血缘，不静默换 Provider。
- [ ] stale 输入不会注入在途 Attempt；局部重跑保留旧 NodeRun 与精确输入。
- [ ] 取消后的迟到回调不复活 Run，费用和隔离产物仍可对账。
- [ ] 对象未完成 hash/媒体 finalize 前不存在可批准 AssetVersion。
- [ ] RenderInputManifest 与 ReleaseManifest 的创建时点、字段和 hash 不混用；PublishAttempt unknown 时不会盲目重发。
- [ ] Inbox/Outbox 重放不重复副作用，dead letter 有告警和受控重放入口。
