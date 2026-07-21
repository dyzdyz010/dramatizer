# Dramatizer 异步执行与真实状态设计

日期：2026-07-21  
状态：设计已批准，待书面规范复核  
适用分支：`feat/dramatizer-mvp`

## 1. 目标

将所有可能执行模型调用、图片生成、质量检查或媒体渲染的生产流程，从 Phoenix LiveView 事件进程中移出，统一交由 Oban 持久任务执行；数据库继续作为唯一事实源，Phoenix PubSub 只承担提交后的失效通知。用户离开页面不会中断任务，重新进入工作台可以从数据库恢复真实状态。

本设计是整体重构的第一阶段。它只处理执行边界、持久状态、幂等、重试、通知和最小界面反馈，不在同一阶段全面拆分工作台布局或完成查询性能重构。

## 2. 已确认边界

- 产品保持单用户、localhost、本地优先，不增加认证、RBAC、租户隔离或 RightsGate。
- 保留 Phoenix、Ecto、Oban、LiveView、PostgreSQL 和本地 AssetStore。
- Fake 与真实 Provider 走同一执行路径，只替换 Provider adapter。
- 中文数据仍是权威语义；Provider prompt 可以由已确认中文语义编译。
- 数据库记录是状态事实源。PubSub 消息不保存业务结果，也不能替代数据库查询。
- Oban 参数仅携带数据库 ID 和稳定的标量选项，不携带领域结构体、二进制资产或 Provider 密钥。
- 普通测试始终使用 Fake Provider；真实 Provider 只由明确的 smoke gate 调用。

## 3. 不在本阶段处理

- 不引入事件溯源、Kafka、RabbitMQ 或第二套工作流引擎。
- 不增加通用 `executions` 表来复制现有 `WorkflowRun`、`NodeRun`、`Attempt` 和 `RenderManifest` 状态。
- 不在本阶段完成 2,400 行 `ProjectWorkspaceLive` 的全面组件拆分。
- 不在本阶段完成所有历史记录分页、查询预算或移动端检查器改版。
- 不改变现有生成结果、选择、Revision、Timeline 或 Asset 的业务语义。

## 4. 方案选择

采用渐进式纵向重构：复用现有领域聚合，先把每条长任务链路拆成“准备并入队”和“后台执行”两个阶段，再通过统一的项目级通知协议驱动 LiveView 局部重载。

未采用局部 `Task.async` 包装，因为它不持久、不能跨页面恢复，也无法提供可靠重试。未采用全量事件溯源重写，因为它会制造第二套事实模型，超出单用户 MVP 的实际需求。

## 5. 架构

### 5.1 统一执行链路

所有长任务遵循同一时序：

1. LiveView 调用领域上下文中的 `enqueue_*` 命令。
2. 命令校验前置条件和幂等键，并用 Ecto.Multi 创建或复用持久记录。
3. 同一个数据库事务内插入唯一 Oban Job，然后一次提交事实记录与 Job。
4. Job 通过 ID 重新加载事实记录，原子地取得执行权并转入运行状态。
5. Job 调用现有领域服务和 Provider adapter。
6. Job 在事务内保存结果或失败状态。
7. 事务提交后广播项目级失效通知。
8. LiveView 收到通知后只重新加载受影响的工作区切片。

LiveView 命令在 Provider 或媒体进程开始前返回。命令成功表示“已存在可追踪任务”，不表示任务已经完成。

### 5.2 事实聚合

不新增通用执行表。复用现有通用工作流包络，同时保留各领域事实：

- `WorkflowRun` 和 `NodeRun`：分析 DAG、结构化文本 Proposal、图片生成流水线、QC 及渲染的持久执行包络。它们表达 blocked、queued、running 和终态。
- `ProviderRequestSnapshot` 和 `Attempt`：每一次真实或 Fake Provider 请求的不可变审计记录，不单独承担整个生成流水线的排队状态。
- `QualityReport`：技术及语义 QC 的领域结果，其执行身份由资产、GenerationSpec、QC kind 和 evaluation key 决定。
- `RenderManifest`：时间线渲染的领域输入、产物和 QC 事实；对应 NodeRun 表达排队、执行和重试。
- 变更传播：继续使用 `ChangeSet` 和 `ChangeNode`，但纳入相同通知协议。

工作区状态由这些记录推导，不从 Oban 内部状态直接推导。Oban 是执行器，不是产品状态数据库。

### 5.3 模块边界

新增或调整以下边界：

- `Dramatizer.Execution.Notifier`：定义项目 topic、事件结构和提交后广播接口。
- `Dramatizer.Execution.JobResult`：把领域错误分类为成功、可重试失败、永久失败或取消，不保存业务状态。
- `Dramatizer.Execution.WorkerLifecycle`：统一取得 NodeRun 执行权、记录 Oban job identity、租约、退避和最终状态。
- `Dramatizer.Execution.ReconcilerJob`：恢复租约已过期且没有可继续 Oban Job 的孤儿 NodeRun。
- `Dramatizer.Workflow.Enqueue`：用 Ecto.Multi 原子创建或复用 WorkflowRun、NodeRun 和对应 Oban Job。
- `Dramatizer.Analysis.enqueue/3`：定义并创建或复用分析 DAG，只入队当前 `queued` 节点。
- `Dramatizer.Analysis.Jobs.AnalysisNodeJob`：执行一个 NodeRun，完成后入队新解锁节点。
- `Dramatizer.Generation.enqueue_pipeline/4`：只用稳定 ID 和已脱敏选项创建生成 WorkflowRun/NodeRun DAG；不得调用 Prompt Proposal 或图片 Provider。
- `Dramatizer.Generation.Jobs.GenerationNodeJob`：按 NodeRun `node_key` 执行 Prompt Proposal 或图片生成，并调用拆分后的 Orchestrator 执行函数。
- `Dramatizer.Quality.enqueue_after_finalize/4`：解锁并入队技术和语义 QC NodeRun；不再在图片持久化事务内同步运行 QC。
- `Dramatizer.Timeline.enqueue_render/2`：创建或复用 RenderManifest、渲染 WorkflowRun/NodeRun 并入队 RenderJob。
- `DramatizerWeb.ProjectWorkspace.Subscription`：封装 LiveView 订阅和通知到工作区切片的映射。

`Orchestrator` 继续负责 Provider、成本、Asset 持久化和不可变 Attempt 结果，但公开入口拆成纯本地准备函数与后台执行函数。真实图片流程的 Prompt Proposal 本身也是独立 NodeRun；因此 LiveView 入队路径不会为了构造最终图片请求而提前访问文本 Provider。

## 6. 幂等与并发

### 6.1 命令幂等

- `WorkflowRun` 继续使用 `(project_id, definition_key, idempotency_key)` 唯一约束。
- `NodeRun` 继续使用 `(workflow_run_id, node_key, input_hash)` 唯一约束。
- `ProviderRequestSnapshot` 继续使用 `(generation_spec_id, request_hash)` 唯一约束。
- `Attempt` 继续使用 `(provider_request_snapshot_id, attempt_number)` 和 `idempotency_key` 唯一约束。
- 生成流水线使用 `(project_id, definition_key, idempotency_key)` 唯一 WorkflowRun；其中 idempotency key 由 GenerationSpec、task type、输入 Revision、参考 Asset、配置快照和正式/候选标志共同决定。
- RenderManifest 必须使用 TimelineVersion、render kind 和内容 hash 构成稳定执行身份；如果现有数据库约束不足，实施时增加最小唯一索引。

同一业务命令重复提交时返回现有事实记录，不创建第二条活跃执行。

### 6.2 Job 唯一性

每种 Worker 使用 `worker + args` 的唯一配置防止同一 NodeRun 同时存在多个可执行 Job，unique states 仅覆盖 scheduled、available、executing、retryable。数据库唯一约束和 NodeRun `active_job_id` 仍是最终防线，不能只依赖 Oban unique period。

### 6.3 执行权

NodeRun 增加 `worker`、`active_job_id`、`lease_expires_at` 和 `next_retry_at` 字段。`worker` 保存受控的现有 Worker 模块名，使 Oban Job 被清理后仍能安全恢复；解析只能命中应用维护的 Worker registry，不能从数据库创建任意 atom。入队事务拿到 Oban job ID 后，将 Worker 名和 job ID 写回 NodeRun。Worker 收到完整 `%Oban.Job{}`，必须在短事务内锁定目标记录并检查当前状态：

- 已成功、取消、过期或被替代：返回 `:ok`，不重复产生副作用。
- 已运行且由另一 job identity 持有且租约未过期：返回 `:ok`，不并发执行。
- queued，或同一 job identity 的 Oban retry：原子取得或续订租约，再发起外部调用。
- 非法状态：持久化明确错误或丢弃 Job，不能静默继续。

外部 Provider 请求仍使用 Attempt `idempotency_key`。资产落盘继续使用 `attempt:<id>:asset`，防止回调或重试产生重复 Asset。

可重试错误在 `job.attempt < job.max_attempts` 时把 NodeRun 恢复为 `queued`，保留稳定 `error_code` 并写入与 Worker backoff 一致的 `next_retry_at`；随后让同一 Oban Job 进入 retryable。最后一次失败才转为 `failed`。手动重试终态失败时创建新的 Oban Job、更新 `active_job_id` 并递增 NodeRun `run_count`。

Worker 捕获普通 exception、throw 和 exit 并交给统一生命周期处理。对于进程被强制终止等无法执行清理的情况，`Execution.ReconcilerJob` 定期扫描租约过期的 running NodeRun：Oban Job 仍在 executing 时延长租约，Job 可继续重试时保持相同 job identity，否则按剩余重试预算重新入队或标记 failed。Reconciler 只能根据数据库和 `oban_jobs` 状态行动，不能重复调用 Provider。

## 7. 状态与转换

### 7.1 持久状态

本阶段不强迫所有表使用同一个枚举；各聚合保留自己的合法状态机。面向工作区的统一状态由后续 StagePolicy 映射为：

- `blocked`
- `ready`
- `queued`
- `running`
- `needs_input`
- `succeeded`
- `failed`
- `stale`
- `cancelled`

`needs_input` 不是后台执行状态，只能由“机器工作已经结束且需要用户选择或确认”的业务事实产生。

### 7.2 分析 DAG

`Analysis.enqueue/3` 创建或复用 WorkflowRun 和 NodeRun，只入队没有未完成父节点的 `queued` 节点。一个节点成功后：

1. 持久化 NodeRun 结果和 `succeeded`。
2. 调用现有 `queue_ready_nodes/1` 解锁子节点。
3. 为新 `queued` 节点插入唯一 Job。
4. 全部节点成功时将 WorkflowRun 标为 `succeeded`。
5. 任一不可恢复节点失败时将 WorkflowRun 标为 `failed`；手动重试后可恢复为 `running`。

不得再由 LiveView 递归执行整个 DAG。

### 7.3 生成和 QC

`Generation.enqueue_pipeline/4` 建立以下 DAG：

1. `prompt_proposal`：通过已选择的 Fake 或真实 adapter 产生并持久化 Provider Prompt Proposal。
2. `asset_generation`：依赖 `prompt_proposal`，从持久 Proposal 和 GenerationSpec 构造不可变 ProviderRequestSnapshot/Attempt，生成并落盘 Asset。
3. `technical_qc` 和 `semantic_qc`：都依赖 `asset_generation`，可以并行执行，各自产生不可变 QualityReport。

纯结构化文本 Proposal 使用只有一个 Proposal NodeRun 的 WorkflowRun。所有目前由 LiveView 直接调用 `StructuredTextProposal.propose/4` 的入口都必须改成该异步包络。

图片成功落盘后，Attempt 先保存结果 Asset，再解锁并入队两个 QC NodeRun。候选可以显示为“生成完成，质检中”；只有要求的 QC NodeRun 进入终态且已有对应 QualityReport 后才进入等待用户选择状态。

QC 必须用稳定 evaluation identity 去重。技术 QC 的瞬时基础设施错误可以重试；确定性不合格报告是成功执行产生的 `fail` 结果，不是 Job 失败。语义 QC 的 Provider 瞬时错误可以重试，结构或策略错误记录为 `evaluator_failed`，不无限重试。

### 7.4 渲染

预览和正式渲染都由 RenderManifest 表示，并各有一个渲染 NodeRun。LiveView 只创建或复用 Manifest、NodeRun 和 Job。RenderJob 根据 NodeRun 输入中的 Manifest ID 加载领域输入，生成文件后原子更新 Manifest 和 NodeRun；重复执行必须复用内容 hash 和目标路径，不能产生平行正式成片。

## 8. 事务与通知

### 8.1 提交后入队

事实记录和 Oban Job 使用 Ecto.Multi 在同一数据库事务中提交；因此不存在“记录已提交但 Job 丢失”或 Job 看见未提交记录的窗口，也不需要内存 Task 补偿。

### 8.2 提交后广播

广播不放在业务事务内部。更新成功返回后调用 `Execution.Notifier.broadcast/3`。消息只包含：

```elixir
%{
  project_id: binary_id,
  resource: :analysis | :generation | :quality | :timeline | :changes,
  resource_id: binary_id,
  event: atom
}
```

topic 固定为 `project:<project_id>:execution`。通知可以丢失、重复或乱序；LiveView 收到后始终从数据库重读对应切片，因此仍保持正确。

### 8.3 Outbox

现有 `OutboxEvent` 继续用于需要持久发布语义的工作流领域事件。本地 LiveView 刷新不依赖 Outbox publisher；PubSub 只是低延迟失效通知。两者职责不得混合。

## 9. 错误分类与重试

统一分类：

- 可重试：网络中断、429、明确的 Provider 5xx、临时文件锁、可恢复的媒体子进程失败。
- 永久失败：无效输入、缺少已确认 Revision、不支持的格式、Provider 明确拒绝、结构校验达到修复上限。
- 未知远端状态：请求可能已被 Provider 接收但本地未取得最终结果；保留 `unknown_remote_state`，不得自动创建新外部请求。
- 取消或过期：记录为 `cancelled`、`superseded` 或对应聚合的过期事实，Worker 幂等退出。

Worker 不把任意异常都自动重试。可重试错误返回 Oban error，并采用有限指数退避；永久失败写入领域状态后返回 `:ok` 或 discard。所有面向用户的错误保存稳定 `error_code` 和已脱敏摘要；日志可以包含 request ID，但不能包含 Provider 密钥或未脱敏 prompt payload。

默认最大尝试次数：分析和结构化文本 3 次、图片生成 3 次、技术 QC 3 次、语义 QC 3 次、媒体渲染 3 次。结构化文本内部已有的 JSON repair loop 属于一次 Job 内的确定性修复流程，不与 Oban 重试次数混淆。

## 10. LiveView 最小改造

本阶段只做支撑异步正确性所必需的 UI 变更：

- mount 时订阅项目 execution topic。
- 增加 `handle_info/2`，按 resource 重载对应 assigns。
- 长任务按钮提交后立即显示“已排队”并禁止重复点击。
- `phx-disable-with` 或等价组件状态用于提交窗口；数据库状态继续控制页面重连后的可用性。
- flash 文案改为“已加入队列”“正在执行”“执行失败”，不能在入队时宣称“生成及 QC 已完成”。
- 页面重连后完全依据数据库恢复进度，不依赖 socket 内临时状态。

阶段状态的完整九态映射、下一步门控、移动端检查器和视觉改版属于第二、三、四阶段。

## 11. 测试策略

所有行为变化使用 TDD，先看到测试因缺少目标行为而失败，再写最小实现。

### 11.1 单元测试

- 错误分类：瞬时、永久、未知远端状态和取消。
- 通知 topic 与事件 payload。
- 各聚合状态转换和非法转换。
- 相同输入生成稳定幂等键。

### 11.2 数据库及 Oban 集成测试

- 相同命令提交两次只产生一个活跃事实记录和一个可用 Job。
- Job 参数只含 ID 和稳定标量。
- Worker 执行成功、失败、Oban retry、手动重试、租约续订、重复执行和已完成短路。
- Reconciler 对仍有活跃 Job、可安全重排和已耗尽预算三类孤儿 NodeRun 分别采取正确动作。
- 分析节点成功后只解锁依赖已满足的子节点。
- Prompt Proposal 和图片生成各自拥有 NodeRun，LiveView 入队过程不调用任何 Provider。
- 图片生成成功后正确解锁并入队 QC NodeRun，而不是在当前进程同步执行。
- RenderJob 重试不产生重复正式输出。
- 使用 `Oban.Testing` 的 manual 模式明确执行 Job，不把测试配置改成全局 inline。

### 11.3 LiveView 测试

- 点击长任务后事件快速返回，页面显示 queued。
- 重复点击不创建第二个任务。
- 收到 PubSub 通知后只刷新对应工作区切片。
- 断开并重新 mount 后从数据库恢复 running、failed 或 succeeded。
- 入队时不显示“已完成”类错误文案。

### 11.4 回归和验收

- 修复 AT-004 对 Attempts 排序的非确定性：查询必须按 RequestSnapshot repair index、Attempt number 和稳定 ID 明确排序，不能只按多个相同的 `attempt_number`。
- 保持现有 Fake 全流程 E2E 的业务断言，并调整为显式等待持久状态，而不是依赖同步事件返回。
- 完整验证依次包括格式检查、warnings-as-errors 编译、完整测试、assets build、Fake E2E。
- 真实 Provider smoke 单独运行并显式启用，不计入普通测试，不允许无意花费。

## 12. 可观测性

日志统一携带 `project_id`、事实聚合 ID、Oban job ID、attempt number、provider request ID 和耗时。状态转换和最终失败使用结构化日志；不新增外部监控平台。

本阶段至少提供可由日志或测试验证的指标事实：排队时间、执行时间、重试次数、最终状态。成本记录继续使用现有 `Costs` 领域模型。

## 13. 数据迁移与兼容

- 优先复用现有字段和索引。
- 新索引使用可重复的迁移，并验证现存数据没有冲突。
- 现有已完成记录不回填虚构 Job。
- 对现有 `running` 但没有对应可用 Job 的记录提供一次性恢复函数或 Mix task；恢复前再次校验事实状态，避免重复外部调用。
- 部署或本地升级顺序是：迁移数据库、发布支持新旧记录读取的代码、启用新入队入口、最后移除同步入口。

## 14. 实施顺序

1. 建立 Notifier、错误分类、WorkerLifecycle、租约和 Reconciler 测试基础。
2. 将 Analysis DAG 改为逐 NodeRun 入队执行。
3. 拆分 Generation 的 pipeline definition、enqueue 和 perform，并新增 GenerationNodeJob。
4. 将 StructuredTextProposal、图片 Prompt Proposal 和 QC 改为显式 NodeRun。
5. 将预览和正式渲染改为 RenderJob。
6. 接入 LiveView 订阅、局部刷新和真实排队文案。
7. 修复 AT-004 非确定排序，调整 Fake E2E 的异步等待。
8. 执行完整验证并更新 STATUS、README 和实现对齐文档中的事实。

每一步必须形成可独立测试和审查的提交，不将下一阶段的视觉或查询重构混入本阶段。

## 15. 验收标准

- LiveView 事件进程不直接执行任何 Provider、QC 或媒体渲染调用。
- 分析、生成、QC 和渲染均可在离开页面后继续，并在重连后恢复状态。
- 相同命令的并发或重复提交不产生重复活跃任务、重复 Asset 或重复正式输出。
- Worker 的重复执行对已终态记录无副作用。
- 用户能区分 queued、running、failed、succeeded 和需要人工操作的状态。
- PubSub 丢失或重复不会影响最终正确性。
- 普通测试不会调用真实 Provider。
- AT-004 不再依赖数据库未声明的返回顺序。
- 格式检查、warnings-as-errors 编译、完整测试、assets build 和 Fake E2E 全部通过后，本阶段才可标记完成。
