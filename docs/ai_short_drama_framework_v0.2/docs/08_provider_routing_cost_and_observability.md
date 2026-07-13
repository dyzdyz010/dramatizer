# 8. Provider 路由、成本、配额与可观测性

## 8.1 三层路由合同

Provider 路由分为三个不可混淆的对象：

```text
CapabilityRequirement       任务需要什么
        +
RoutePolicy                 允许如何选择
        +
Catalog/Health/Quota/Rights/Budget 当前可行性
        ↓ resolve
ResolvedExecutionPlan       本次 Attempt 固定执行什么
```

- `CapabilityRequirement` 来自模型无关 GenerationSpec/节点合同；
- `RoutePolicy` 是版本化运营策略，不含运行结果；
- `ResolvedExecutionPlan` 是不可变决策快照，固定 Provider、模型版本、Adapter、能力证据、健康快照、`allowed` RightsGateSnapshot 和 Budget Gate；
- `ProviderAttempt` 只引用一个 plan。首次提交后 plan 不得在运行中变更。

## 8.2 CapabilityMode 与 Requirement necessity

两组枚举回答不同问题：

### 节点 CapabilityMode

| mode | 含义 | 路由行为 |
|---|---|---|
| `AUTOMATED` | 由 Provider/Worker 自动完成 | 必须解析 required capabilities、route 和 budget |
| `RULE_BASED` | 由本地确定性规则完成 | 选择固定 handler/version，不调用外部生成 Provider |
| `MANUAL` | 由人工完成 | 创建 HumanTask，明确表单、责任人和恢复动作 |
| `UNAVAILABLE` | 当前无实现 | required 节点阻塞；optional 节点只可按显式策略跳过 |

CapabilityMode 是节点执行方式，不是 Provider 健康状态，也不是能力是否 required。

### CapabilityRequirement necessity

- `required`：任何一个不满足都淘汰候选 Provider；不得通过“尽力而为”继续收费调用。
- `optional`：不满足不淘汰，但能力缺失进入 plan 的 `capability_resolutions`，可用于评分和后续 QC/人工门。

约束示例：`video_generation` required，`aspect_ratio = 9:16` required，`native_audio` optional，`duration_seconds <= 10` required。Router 只比较 typed constraints，不解析自由文本提示词猜能力。

## 8.3 静态能力与动态健康分离

### Provider Catalog：静态、版本化

Catalog 声明：

- Provider/Adapter 版本和数据地域；
- 精确模型 ID 与模型版本；
- 支持的输入/输出模态、尺寸、时长、参考资产、seed、异步回调/取消等能力；
- 定价版本和是否启用。

Catalog 变更产生新 `catalog_version`。在途 plan 继续引用旧版本。Provider 宣称支持不等于当前可调用。

### Health Snapshot：动态、带有效期

Health 是定时探针和真实流量统计的观测快照，包含：`healthy/degraded/unhealthy/unknown`、15 分钟成功率、P95 延迟、rate-limit 余量和 circuit 状态。每个快照有 `observed_at/valid_until`；过期健康数据按 `unknown`，不能伪装 healthy。

健康变化不改 Catalog；Catalog 变化也不抹掉历史健康。Router 必须把实际使用的 health snapshot ID 固定进 plan。

## 8.4 RoutePolicy 与解析算法

RoutePolicy 以 `id + version + task_type` 固定，包含：required/optional requirement、候选顺序、允许健康状态、fallback error allowlist、最大 fallback 次数和选择策略。

确定性解析顺序：

1. 根据节点 CapabilityMode 决定 automated/rule/manual/unavailable 路径；
2. 固定 intended-use hash、policy 版本和 Catalog 版本；
3. 淘汰 disabled Provider/model；
4. 对所有 required capability/constraint 做静态匹配；
5. 读取未过期 Health 与 Quota Snapshot，应用 circuit/rate-limit 守卫；
6. 对候选 Provider 的精确 policy revision、输入闭包和 intended use 执行 RightsGate；`blocked` 淘汰候选，`manual_review` 创建 Rights HumanTask 并令 GenerationTask/NodeRun 进入 `rights_review/waiting_human`；
7. 为 Rights `allowed` 且未过期的候选按同一输入估算费用；
8. 按 priority/cost/latency/weighted score 解析一个候选；
9. 运行 Budget Gate；`deny` 进入 `budget_blocked`，`approval_required` 创建 Budget HumanTask 并进入 `budget_review`；两者都不创建可执行 plan；
10. 只有 decision=`allow` 且非空 reservation 原子处于 `held` 时，才将全部证据写入 `ResolvedExecutionPlan` 并允许编译 ProviderRequestSnapshot/创建 Attempt。

步骤 3–5 只是利用静态/动态快照做无副作用的候选预筛，以便确定哪些 Provider policy 需要参与 RightsGate；它们不创建 plan，也不构成业务放行。步骤 6 是第一个授权门，最终 Route 必须同时固定预筛证据和 `allowed` Rights snapshot。因而第 7 章的执行顺序应读作“候选预筛 → Rights → 最终 Route/Budget”，不得实现成先 pin plan、后补 Rights。

步骤 3–5 结束时 Provider Routing Service 必须创建不可变 `CandidatePrefilterSnapshot`，固定 GenerationTask/GenerationSpec/intended-use、Catalog/Health/Quota/RoutePolicy revision、每个 Provider/model 的 capability match、eligible、rejection codes、evidence hash 和整体 snapshot hash。`eligible_provider_count` 与结果数组的一致性、所引用快照存在且在求值时有效、ResolvedExecutionPlan 的 Provider/model 确实来自同快照的 eligible result，均由建 plan 事务校验。注意 `GenerationTask.candidate_count` 是要生成的输出候选槽数，`eligible_provider_count` 是可用 Provider/model 数量，两者是正交维度，禁止比较相等。若此时无候选，GenerationTask 进入 `prefilter_blocked`；若已通过 Rights 但步骤 7–8 无最终可执行候选，才进入 `routing_blocked`。两者都保存逐候选淘汰证据，但前者明确不存在 Rights/Budget/plan/Attempt：

- required AUTOMATED 节点若有明确 MANUAL 降级分支，则该分支的 NodeRun 进入正式状态 `waiting_human` 并创建 HumanTask；
- 无人工或其他恢复分支时，required NodeRun 进入 `failed`，并按 Definition 的 completion policy 令 WorkflowRun 进入 `failed` 或 `partially_completed`；
- optional 节点只有在 Definition 声明 `skip_by_policy` 时跳过；
- 绝不返回 `completed` + 空资产。

Catalog/Health/Quota/RoutePolicy 改变可从 `prefilter_blocked` 重新进入 `prefiltering`；Rights 后的路由输入改变可从 `routing_blocked` 重新进入 `routing`。操作者放弃则进入 `failed`。Rights/预算等待路径的恢复闭环见第 6 章，不允许通过后台轮询把失败悄悄改成 plan。

weighted score 的权重和规范化公式属于 policy version；同一次解析不得读取两套权重。相同快照和输入应得到同一 plan；Router 不使用未记录随机性。

## 8.5 Pin 与 fallback

`ResolvedExecutionPlan` 固定：

- Provider、endpoint/region、model ID/version；
- Adapter 与 request compiler version；
- Provider Catalog、RoutePolicy、Health、Quota 快照；
- required/optional capability 的逐项满足证据；
- RightsGateSnapshot ID/hash、`allowed` 决策、expiry、intended-use hash；
- CostEstimate、Budget decision=`allow`、非空 BudgetReservation ID，以及 pin 时 reservation status=`held`；
- resolution kind、时间和 correlation context。

Schema 禁止把 `deny/approval_required/null reservation` 塞入 ResolvedExecutionPlan。BudgetGateDecision 可记录这些路由结果，但它们只能驱动等待/失败状态。Plan pin 后若 Rights expiry 到达或 intended use 改变，plan 失效，必须重新求值，不能只刷新时间戳。

首次路由 `resolution_kind=initial`。提交后即使健康恶化，也不能把同一 Attempt 的 provider/model 字段改成别家。

fallback 的守卫：

1. 旧 Attempt 已进入明确失败/超时/取消/对账终态，或 policy 明确允许在途 hedging（MVP 默认禁止）；
2. normalized error category 在当前 route candidate 的 `fallback_on` allowlist；
3. 未超过 max fallbacks 和总 deadline；
4. 重新读取健康、Quota、目标 Provider policy，重新执行 RightsGate、成本估算和 Budget Gate；
5. 创建新 plan，写 `previous_execution_plan_id` 和 `fallback_reason`；
6. 创建新的 `ProviderAttempt(kind=fallback)`，保留同一 generation task/candidate business key，但使用新 provider submission key。

Provider 只是不够便宜、出现艺术质量不佳或用户想尝试新风格时，应走 regenerate/新 Task，而不是把它伪装成基础设施 fallback。

## 8.6 路由与 Reservation 状态转移

### Resolution

| 当前阶段 | 事件 | 结果 | 守卫 |
|---|---|---|---|
| request received | capability mismatch | rejected candidate | required constraint 不满足 |
| candidate eligible | unhealthy/circuit open | rejected candidate | health snapshot 未过期且 policy 不允许 |
| candidate eligible | rights blocked | rejected / rights review | blocked 淘汰；manual_review 创建 HumanTask，均不创建 plan |
| candidate eligible | estimate created | budget check | 定价维度和输入用量完整 |
| budget check | allow + reservation held | plan pinned | 原子预算扣留成功 |
| budget check | deny | budget blocked | 不创建 plan/Attempt，不调用 Provider |
| budget check | approval required | budget review | 创建 HumanTask；批准后重新估算/预留，不直接修改旧 decision |
| pinned | Provider failure allowlisted | new fallback resolution | 新快照、新 estimate、新 reservation |

### BudgetReservation

| 当前状态 | 事件 | 下一状态 | 守卫 |
|---|---|---|---|
| — | reserve | `held` | 在预算账户行锁/原子计数下 remaining 足够；estimate 未过期 |
| `held` | actual settled | `consumed` | actual 与 Attempt 关联；释放差额或登记超额 |
| `held` | attempt not submitted/cancelled | `released` | 能证明不会产生该 Attempt 费用 |
| `held` | TTL elapsed before submit | `expired` | 不允许继续提交；重新估算 |

`consumed/released/expired` 为终态。Provider 状态未知时 reservation 不可提前释放，直到查询、账单或保守 TTL 对账策略给出结论。

## 8.7 成本合同：estimate、reservation、actual

成本从第一个真实 Provider 前就是硬门禁，而不是 M5 报表功能。

### Estimate

CostEstimate 固定 provider/model/pricing version，按 line item 保存：计费维度、预估 usage、unit price、subtotal 和 total。`confidence`：

- `exact`：固定请求费或可精确计算；
- `bounded`：有明确上界，reservation 取上界；
- `best_effort`：Provider 计费规则无法得出可靠上界；策略可增加 safety multiplier 或要求人工批准。

### Reservation / Budget Gate

预算作用域可为 project、episode、workflow run 或 user。MVP 采用单一账本币种；Money 必须是十进制定点字符串 + ISO 4217 currency，禁止二进制浮点。不同币种不能直接相加；若未来支持换汇，必须保存 FX rate/source/timestamp，不能使用“当前汇率”重算历史。

Budget Gate 决策：`allow`、`deny`、`approval_required`。只有 `allow` 且 reservation `held` 可提交真实 Provider。候选数 N 必须反映在 estimate/reservation，不可只预留一个候选费用。

### Actual

每个 Attempt 都记录 actual usage/cost，包括失败、取消、timeout 和迟到结果；来源为 provider response、invoice 或本地计算。Actual 使用与 estimate 相同的计费单位字典（request、candidate、video_second、token 等）和 pricing version。

结算规则：

- actual < reservation：消费 actual，释放差额；
- actual = reservation：全部消费；
- actual > reservation：全部 actual 入账并触发 overage 告警/后续 Budget Gate 收紧，不能篡改历史 estimate；
- Provider 暂无 usage：Attempt 可终态，但 cost 标为 pending reconciliation；账单到达后追加 ActualCost，不覆盖运行记录。

报表必须区分 estimated、reserved、actual、refunded；“成本为 0”与“成本未知”不是同一值。

## 8.8 Quota 与限流

Quota Snapshot 保存窗口、limit/used/remaining/unit 和观测时间。它是动态证据，不是强一致真值。提交前仍需 provider-scoped token bucket/concurrency limiter；取得本地 permit 后再 submit，释放 permit 不等于释放预算 reservation。

429 统一分类为 `rate_limit`，按 Retry-After 与 retry policy 处理；不得用无限快速重试制造放大流量。Quota 不足可触发允许的 fallback，但必须重新估算成本和预留预算。

## 8.9 完整 correlation chain

每条日志、metric exemplar、outbox、callback inbox 和 Provider Request Snapshot 应携带当时已存在的链：

```text
correlation_id
project_id
episode_id? / shot_plan_revision_id?
workflow_run_id
node_run_id
generation_task_id
provider_attempt_id?
asset_version_ids[]
trace_id / span_id / trace_flags
```

链按阶段单调丰富：路由时 Attempt 尚未创建，`provider_attempt_id=null`；创建 Attempt 后的新事件必须补齐；资产 finalize 后附加 AssetVersion ID。不可回写不可变旧记录伪造“当时已知”，查询层用 ID 连接完整链。

业务 ID 不替代 trace ID：前者用于长周期审计和对账，后者用于一次分布式执行的时序分析。

## 8.10 Trace 与异步 span link

同步短调用使用 parent-child span。队列、长时间 Provider job、callback、人工暂停/恢复、retry/fallback 和对象 finalize 不强行保持数小时的父 span；新消费 span 使用 OpenTelemetry span link 指向生产/提交 span，并标注原因：

- `async_dispatch`
- `callback`
- `retry`
- `fallback`
- `asset_finalize`
- `manual_resume`

每次 Attempt 使用独立 span；retry/fallback span link 到前一 Attempt，而非伪装成同一个 span。Provider job ID 作为低基数日志字段/trace attribute；不要直接把 prompt、用户文本或签名 URL 作为 span attribute。Metric label 只使用 provider、model family、task type、normalized status/error 等受控低基数字段，具体实体 ID 通过 exemplar/trace 查询。

## 8.11 日志脱敏与敏感快照

默认禁止日志记录：

- API key、Authorization、Cookie、callback secret/signature 原文；
- 签名 URL query、对象存储 credential；
- 完整 Provider request/response、prompt body、未发布剧本和个人信息；
- 声音克隆参考、肖像素材字节和生物特征 embedding；
- Provider 原始错误中可能回显的请求内容。

结构化日志先按 schema allowlist，再执行 redaction policy；敏感键递归处理，不能只过滤顶层。ID 可保留，用户提供的自由文本默认 drop/hash。错误日志只保存 normalized code、safe message 和受控 safe_details。

ProviderRequestSnapshot 与日志不同：它是独立执行记录，不是 AssetVersion，也不进入候选/时间线。每个 Attempt 必填 `provider_request_snapshot_id + snapshot_hash`；快照固定 plan、Provider/model/Adapter、GenerationSpec、Rights snapshot/expiry/intended-use hash、解析后的输入 asset/hash、submission key 和规范化 payload hash。完整请求以加密对象引用保存并最小权限访问；secret、临时签名和 Authorization 不进入快照。`canonical_payload_hash` 对规范化、去 secret 的实际业务 payload 计算，redacted preview/hash 不可冒充请求 hash。

回调验签必须使用原始 request bytes；验签后再解析和脱敏。无效回调不可把原始 body 打到日志。

## 8.12 指标与告警

首个垂直切片就采集：

- routing eligible/rejected counts（按原因）；
- plan resolution latency、health snapshot age；
- Provider submit/complete latency、normalized failure rate、unknown remote count；
- retry/fallback/regenerate 次数与采用率；
- estimated/reserved/actual cost、overage、pending reconciliation；
- quota remaining、429、circuit state；
- callback duplicate/invalid/dead-letter；
- upload finalize/quarantine/orphan；
- generation multiplier（总候选/最终采用）与每个 approved second 实际成本。

告警至少覆盖：无 eligible route、预算超额、reservation 长时间 held、Attempt unknown remote、callback 签名失败突增、outbox/inbox dead letter、健康快照过期、ActualCost 长期未对账。

## 8.13 写入权限

| 数据 | 写入者 | 禁止行为 |
|---|---|---|
| Provider Catalog / RoutePolicy | Provider Registry，需配置审计 | Adapter 自行改 policy |
| Health / Quota Snapshot | Health & Quota Collector | Router 覆盖历史快照 |
| RoutingRequest / ResolvedExecutionPlan | Model Router | Attempt 在运行中改 plan |
| RightsGateSnapshot / Rights HumanTask | Rights Service | Router 伪造 allowed 或延长 expiry |
| ProviderRequestSnapshot | Provider Gateway/Adapter | 作为 AssetVersion、覆盖历史请求或保存 secret |
| CostEstimate | Pricing Service/Router | 用 actual 反写 estimate |
| BudgetReservation | Budget Service 原子命令 | Provider Adapter 绕过 gate |
| ActualCost | Usage Reconciler/Provider Gateway | 失败 Attempt 不计费或记 0 代替 unknown |
| Correlation/Trace | 各服务在受控 telemetry SDK 中追加 | 日志记录 secret/prompt/签名 URL |
| RedactionPolicy | Security/Platform 管理入口 | 业务代码临时关闭脱敏 |

## 8.14 验收检查

- [ ] required capability 缺失时不提交 Provider；optional 缺失会留证据但可按 policy 继续。
- [ ] Catalog 静态能力、Health 动态观测和 CapabilityMode 不共享一个模糊字段。
- [ ] 每个 Attempt 能复原 policy/catalog/health/quota/pricing/budget 的解析时快照。
- [ ] 每个 plan/Attempt 固定同一个未过期 allowed Rights snapshot hash 和 intended-use hash；manual_review 有 HumanTask。
- [ ] ResolvedExecutionPlan 无法通过 Schema 携带 deny、approval_required、null reservation 或非 held pin 状态。
- [ ] 每个 Attempt 必填独立 ProviderRequestSnapshot ID/hash，且快照不是媒体资产。
- [ ] 首次 route 已 pin；fallback 创建新 plan、新 reservation 和新 Attempt，并记录原因。
- [ ] N 候选提交前按 N 估算和预留，Budget deny 时 Provider 侧不存在 job。
- [ ] 失败/取消 Attempt 的 actual usage 仍能结算；unknown 不显示为 0。
- [ ] 不同币种不会未经 FX 快照直接汇总，金额计算不使用浮点。
- [ ] 可从 Release/Asset 追到 Attempt，再追到完整成本和 trace；异步边使用 span link。
- [ ] 日志、span、Sentry 和 dead letter 中无 key、签名 URL、prompt body 或敏感媒体内容。
- [ ] 重复 callback 与 outbox 重放不会重复结算 cost/reservation。
