# 分析工作流恢复设计

## 问题

相同正文会复用既有 `whole_novel_analysis_v1` WorkflowRun。异步执行字段上线前遗留的 NodeRun 可能处于 `running`，但没有 `worker`、`active_job_id` 或租约；失败节点也可能没有可解析的 worker。现有重新入队流程只处理 `queued` 根节点，因此会把 WorkflowRun 标成 `running`，却不创建任何 Oban job。节点重试入口还错误地颠倒了 `Repo.get!/2` 参数。

## 目标行为

- 已成功的幂等分析保持不变，不重复执行。
- Provider 模式、工作流 schema 版本和每个任务的脱敏解析执行配置进入 Workflow 的幂等身份并固化到 NodeRun；Fake 与 OpenAI 不复用同一个分析 run，worker 不读取可能已经变化的进程模式或项目配置。
- 重新启动未成功的分析时，在同一事务内识别当前可运行的失败节点和无执行所有权的遗留运行节点，将其恢复到 `queued`，并绑定 `AnalysisNodeJob`。
- 若无执行所有权的节点已经存在 `submitted` 或 `unknown_remote_state` Attempt，则将其稳定为远端状态未知并禁止自动重提。
- Provider 请求身份不包含 NodeRun 的生命周期 `run_count`；节点恢复后复用已经成功并持久化校验输出的 Attempt，不重复提交远端请求。
- 保留已成功节点；仅恢复满足父依赖的节点。
- WorkflowRun 恢复到 `running` 时清除旧 `completed_at`，数据库状态必须与执行状态一致。
- Analysis、Analysis Worker 和 Reconciler 的聚合事务统一先锁 WorkflowRun、再锁 NodeRun；协调器续租、保留或重排节点时同步恢复 WorkflowRun。
- 分析节点的显式重试由 Analysis 上下文决定 worker，不依赖遗留的 `node.worker`。
- 入队失败必须整体回滚；通知只在事务提交后广播。
- 阶段状态、分析审阅、分集候选和选择动作只消费最新 Analysis WorkflowRun 对应的 AnalysisSnapshot；完整加载和 PubSub 增量刷新遵循同一规则。

## 验证

- 回归测试构造“旧运行节点无 worker/job + 失败根节点”的既有幂等 WorkflowRun，确认重新启动会创建任务、恢复状态并最终完成六节点 DAG。
- LiveView 测试确认点击“仅重试本节点”不再使进程崩溃，并确实绑定 Analysis job。
- Workflow 测试确认从终态恢复为 `running` 会清除 `completed_at`。
- Attempt 回归覆盖 submitted/unknown 禁止重提、failed 节点显式重试拦截，以及跨 `run_count` 恢复复用 succeeded Attempt。
- 配置回归确认 NodeRun 冻结完整任务配置，项目覆盖变化会产生新运行身份，既有 Worker 仍使用原配置。
- LiveView 回归确认最新运行失败或重新入队时，旧快照不会继续出现在审阅/候选中；已挂载页面收到 workflow 通知后无需 remount 即清空旧候选，伪造选择事件也不会创建 Proposal。
- 最终验证为 `mix test` **183 passed、1 excluded**，Fake Chromium E2E **1 passed（45.5s）**；格式、warnings-as-errors 编译、assets build 与 `git diff --check` 全部通过。
