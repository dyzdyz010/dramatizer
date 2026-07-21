# Dramatizer 当前状态

**检查点日期：** 2026-07-21

**当前分支：** `feat/dramatizer-mvp`（隔离 worktree：`.worktrees/dramatizer-mvp`）

**工作阶段：** MVP、production-workspace-v2 与 durable-async-execution 第一阶段均已实施；Fake 全量门禁通过，真实 OpenAI 既有脱敏证据复核通过

## 当前产品状态

- 产品是本机、单用户、多 Project、无登录/认证/RBAC/RightsGate 的功能优先 AI 短剧制作台。
- 从 TXT、Markdown、文本型 PDF 小说导入，到全文分析、Narrative、VisualDesign、ReferenceSet、Directing、镜头关键帧、双层 QC、人工选择、字幕时间线、预览及 H.264/AAC 正式 Animatic，已形成同一持久化闭环。
- Narrative、VisualDesign、ShotPlan 与模型覆盖使用领域表单；浏览器验收会检查普通创作页面不存在裸 JSON 编辑面。
- 真实路径使用 `gpt-5.6-terra` 完成结构化文本、图片提示词补全和多模态语义 QC，使用 `gpt-image-2` 完成图像生成/编辑。模型与参数仍可按系统、Project 和单次任务覆盖。
- 普通测试与 E2E 始终钉死 Fake；只有显式真实烟测允许访问 OpenAI。`scripts/real-smoke.ps1` 默认只复核脱敏证据，必须加 `-Force` 才会产生新的付费调用。

## 持久异步执行事实

- D-061 已落地：全文分析、三类阶段 Proposal、图片 Prompt Proposal、图片生成、技术/语义 QC、预览和正式渲染均由 Oban Worker 执行，LiveView 不再直接运行 Provider、QC 或媒体长任务。
- WorkflowRun/NodeRun 表达 DAG 与执行状态；ProviderRequestSnapshot/Attempt、QualityReport 和 RenderManifest 保留各自领域事实。Oban 是执行器，不是产品状态事实源。
- 入口命令在同一个数据库事务中创建或复用 WorkflowRun、完整 NodeRun 拓扑并插入根 Oban Job；下游节点也在一次事务内完成 `blocked → queued`、唯一 Job 插入和 `active_job_id` 绑定，不存在已排队但无任务的提交窗口。
- NodeRun 成功/失败与下游 DAG 推进或 WorkflowRun 终态同事务提交；终态 Job 重放会幂等补做推进，能够修复旧版本遗留的“节点已终态但流程未前进”现场。
- WorkerLifecycle 统一执行权、job identity、租约、有限退避、终态和重复执行短路；Reconciler 每分钟检查租约过期的 running 节点，只通过 Worker registry 恢复，不从数据库字符串创建任意模块。
- JobGuard 把未预期的 raise/throw/exit 转成脱敏的稳定生命周期失败；真实适配器的 `rate_limited`、`provider_unavailable` 和媒体 Worker 暂态故障进入有限重试，确定性 QC 不通过仍保留为 QualityReport。
- 图片流水线是 `prompt_proposal → asset_generation → technical_qc + semantic_qc`；结构化 Proposal 使用独立单节点 Workflow；Timeline 预览与正式输出使用 RenderManifest + RenderJob。
- Provider 提交超时但远端结果不明时统一进入稳定的 `unknown_remote_state`，文本提案、图片生成和语义 QC 都不得自动发起新的付费请求。
- 项目级 PubSub 消息只承担失效通知；事务提交后再次广播最终失效事件，LiveView 再按 analysis、generation、quality、timeline、changes 或 execution 切片重读 PostgreSQL，不会停留在提交前的中间状态。离开页面和重新挂载不会丢失进度。
- UI 区分 queued、running、failed、unknown、ready 与人工处理状态；阶段状态由当前 WorkflowRun/NodeRun 派生，历史 Attempt 继续显示在审计面板但不再把已恢复流程永久标成失败。“已加入队列”只表示任务已被接受，不能表示已经完成。

详细设计与计划：

- [`docs/superpowers/specs/2026-07-21-async-execution-and-truthful-status-design.md`](docs/superpowers/specs/2026-07-21-async-execution-and-truthful-status-design.md)
- [`docs/superpowers/plans/2026-07-21-async-execution-and-truthful-status.md`](docs/superpowers/plans/2026-07-21-async-execution-and-truthful-status.md)
- [`docs/implementation-alignment.md`](docs/implementation-alignment.md) D-061

## 2026-07-21 fresh gate

- `mix.bat format --check-formatted`：通过。
- `mix.bat compile --warnings-as-errors`：通过。
- `mix.bat test`：**166 passed，1 excluded**，退出码 0。两条 `worker execution raised` 是异常恢复用例的预期观测；测试结束阶段另有两条 Postgrex 客户端随 LiveView 测试进程退出而断开的日志，均不影响结果。
- `mix.bat assets.build`：Tailwind 与 esbuild 通过。
- `./scripts/e2e.ps1`：Chromium **1 passed（31.6s）**。覆盖独立数据库迁移、项目创建、模型覆盖、小说导入、异步六节点分析、三类异步 Proposal、8 个参考槽候选及完整主图选择、6 个镜头候选与 QC、字幕编辑、异步预览/正式渲染、MP4/SRT 下载与 FFprobe、提交后状态刷新、失败恢复、重复乱序回调去重、成本幂等、全阶段路由及无裸 JSON 编辑面。
- v0.2 合同校验：**8 schemas、7 mapped examples、33 negative cases** 与全部本地 Markdown 链接通过。
- `./scripts/real-smoke.ps1`：**PASS（复用最近一次成功的真实 Provider 脱敏证据，不产生新费用）**；证据包含 6 个分析节点、8 张参考图、6 张镜头候选、14 份技术 QC、14 份语义 QC、3 个 Clip、49 个请求快照、48 个 Provider request ID、220,027 usage units 和 1080×1920 正式视频。此次异步重构后未执行 `-Force` 付费重生成，因此该证据只证明既有真实闭环记录仍可通过复核，不冒充本轮新调用。

## 关键安全与成本边界

- `DRAMATIZER_PROVIDER` 只接受 `fake` 或 `openai`；未知值和 OpenAI 模式缺失 API Key 都会拒绝启动，不会静默回退 Fake。
- 普通 `mix test` 即使根目录 `.env` 为 OpenAI 也强制 Fake，避免隐式付费。
- Provider 密钥不进入 Job 参数、RequestSnapshot、日志或 PubSub payload；快照与错误摘要经过脱敏。
- Provider 不返回货币费用时只显示 usage 与“实际费用未返回”，不估算或虚构金额。
- 当前根目录 `.env` 配置为 `openai`，但检查点时 **4000 端口没有常驻服务**。下次运行 `scripts/dev.ps1` 后，网页中的生成操作会真实调用并可能计费；离线开发前应把 `.env` 改回 `DRAMATIZER_PROVIDER=fake`。

## 已知范围边界

- 本版本不实现认证、权限、租户隔离、RightsGate、内容安全工作台、真实视频、配音、音乐或发布。
- Suno 尚未接入；正式 Animatic 使用显式 AAC 静音占位轨。
- 图像遮罩编辑的领域合同与 lineage 已保留，首版网页只开放提示词编辑。
- 本阶段未全面拆分大型 ProjectWorkspaceLive，也未完成历史记录分页、查询预算与移动端检查器改版；本轮只改造了异步正确性所需的命令、状态和局部切片刷新。

## 仓库与运行交接

- 当前工作在隔离 worktree 内完成；主工作区未被切换或清理。
- `.omc/` 是既有未跟踪目录，本轮未读取其内容、未修改、未暂存，也不得随提交带入。
- 根目录 `.env`、运行日志、E2E 视频/截图、真实烟测证据和生成素材均由 Git 忽略。
- 本轮没有启动 4000 常驻服务；E2E 使用的 4100 临时服务已由脚本 `finally` 正常回收。
- 推荐使用 `./scripts/dev.ps1` 启动、`./scripts/test.ps1` 复验；完整浏览器验收使用 `./scripts/e2e.ps1`。

## 交接结论

- durable-async-execution 计划的实现与 Fake 验收已完成，数据库恢复、幂等、未知远端状态和真实排队文案均有自动化覆盖。
- 既有真实 OpenAI 脱敏证据仍通过无费用复核；若要证明当前异步代码实际完成一轮新的真实 Provider 闭环，必须由用户明确决定运行 `./scripts/real-smoke.ps1 -Force` 并接受费用。
