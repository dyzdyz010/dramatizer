# Dramatizer 当前状态

**检查点日期：** 2026-07-15

**当前分支：** `feat/dramatizer-mvp`（隔离 worktree：`.worktrees/dramatizer-mvp`）

**工作阶段：** Task 1–17、全部 fresh gate、发布和常驻浏览器烟测均已完成；系统已留在本机供验收

## 当前事实

- 产品是本机、单用户、多 Project、无登录/认证/RBAC/权利安全子系统的功能优先制作台。
- 冻结需求是 [`docs/superpowers/specs/2026-07-15-dramatizer-mvp-prd.md`](docs/superpowers/specs/2026-07-15-dramatizer-mvp-prd.md)，逐文件计划是 [`docs/superpowers/plans/2026-07-15-dramatizer-mvp.md`](docs/superpowers/plans/2026-07-15-dramatizer-mvp.md)，历史对齐决策是 [`docs/implementation-alignment.md`](docs/implementation-alignment.md)。
- Phoenix/LiveView、PostgreSQL/Oban、本地内容寻址 AssetStore、全文 Parser、分析 DAG、Draft/Revision、视觉权威、Fake/OpenAI Provider、两层 QC、ChangeSet/stale、Timeline/字幕、FFmpeg 和本地备份恢复均已进入同一持久化闭环。
- TXT、Markdown 和带文本层 PDF 按全文导入；不做自动分段。AI 结构化结果先成为 Draft/Proposal，只有明确确认才形成不可变 Revision。
- 真实路径由 `gpt-5.6-terra` 完成结构化文本、图像提示词补全和多模态语义 QC，`gpt-image-2` 完成图像生成/编辑。AI 补全的 Provider prompt 不能覆盖已确认的中文角色、场景、镜头权威数据。
- 模型配置按系统默认 → Project 覆盖 → Task 一次性覆盖解析；ProductionProfile 允许 Project 默认与单集冻结覆盖。CorePrompt 隐藏且不可编辑，PromptAppendix 按任务类型追加修订。
- Fake 与 OpenAI 共用 GenerationSpec、ProviderRequestSnapshot、Attempt、CostEntry、AssetVersion、QC、SelectionDecision 和 TimelineVersion；真实流程不是旁路演示。

## 2026-07-15 fresh gate

- `mix.bat format --check-formatted`、`mix.bat compile --warnings-as-errors`、`mix.bat assets.build`：全部通过。
- `./scripts/test.ps1`：**100 passed，1 excluded，287.8s**；包含 Windows 非默认代码页 Unicode PDF 回归，排除项仅为必须显式启用的真实 Provider 标签。
- `./scripts/e2e.ps1`：Chromium **1 passed，48.7s**；完成 Project 创建、小说上传、Fake 分析/制作、人工确认、选择、字幕/Timeline 编辑、预览、正式导出、失败恢复、全阶段路由和 MP4/SRT 下载。
- `./scripts/real-smoke.ps1 -Force`：真实 Provider **2 passed，703.9s**；6 个分析节点、3 张参考图、6 张镜头候选、9 份技术 QC、9 份 Terra 语义 QC、3 个最终 Clip 全部完成。
- 真实门禁持久化 **33** 个 ProviderRequestSnapshot 和 **33** 个 Provider request ID；usage 为 **116,998 total tokens**（85,734 input、31,264 output，含 18,576 input image tokens 与 990 output image tokens）。API 未返回币种费用，33 条 actual 记录的金额明确为 `unavailable`，不是零。
- 真实正式输出经 FFprobe 验证为 **1080×1920、H.264、yuv420p、AAC 双声道静音轨**；完整最终 Clip 可回溯到 Asset/QC/Attempt/RequestSnapshot/GenerationSpec/ShotPlan/Visual/Narrative/Source。
- 首次 fresh 真实运行遇到两次脱敏的传输层 `closed`，系统保留失败 Attempt 并执行一次节点恢复；没有把瞬态错误当成功。官方状态正常后，全新强制运行完整通过。
- v0.2 合同校验：**8 schemas、7 mapped examples、33 negative cases** 与全部本地 Markdown 链接通过。
- Python 媒体 Worker：`compileall`、`unknown_command`、`unsupported_protocol` 探针通过；Elixir Worker 超时测试证明调用方不会永久阻塞。
- 用户实测 PDF 曾因 Windows Python stdout 为 GBK、正文含代码页外 Unicode 而在协议输出阶段失败；Worker JSON 已改为代码页无关的 ASCII escape。回归测试先复现 `UnicodeEncodeError`，修复后 Worker 4/4、Source/Parser/LiveView 17/17、全量 100/100 通过；另用含 `𠮷` 与 emoji 的文本层 PDF 完成真实浏览器上传，显示 37 字、rev 1、已就绪。诊断产生的 DB/AssetStore 数据随后按精确 ID 清理，用户 Project 保留。
- 本地运维演练：`dramatizer_dev` 完整备份到独立目录，再恢复至 `dramatizer_restore_gate` 与独立 AssetStore；恢复后一致性检查通过，write checkpoint 已释放。
- `.env` 经 Git 忽略；已对全部 tracked 文件执行当前 OpenAI Key 精确值扫描和 OpenAI/Gemini/私钥常见模式扫描，命中均为 0；`git diff --check` 通过。

## 集中代码复核

| 风险类 | 复核结论与直接证据 |
|---|---|
| 数据不变量 | `ModelOverride` 拒绝非正整数候选数；LiveView 物化层再次防御；探索 GenerationSpec 不能进入正式 Timeline；`ProjectsTest`、`OrchestratorInvariantsTest`、`TimelineTest` 直接覆盖。 |
| 跨 Context 写入 | Web 层只调用 Projects/Sources/Revisions/Generation/Quality/Timeline 等命令 API；关键多表操作使用 Ecto.Multi/事务；全量测试与 LiveView 闭环通过。 |
| 终态回退 | Workflow、Attempt、Revision、TimelineVersion 的允许转换和不可变触发器均有直接失败断言；`WorkflowTest`、`GenerationTest`、`RevisionsTest`、`TimelineTest` 通过。 |
| 重复外部副作用 | Prompt 提案按权威输入复用成功 Attempt；Inbox/Outbox 幂等；Semantic QC 重复提交复用完成报告；重复/乱序回调只产生一个资产和一条 actual；Fake AT-002 与 E2E 故障恢复通过。 |
| 错误与密钥脱敏 | Provider 快照只保存 `credential_ref`，不保存 Key/Authorization；错误元数据只保留稳定类别、request id 与公开 Provider 字段；真实日志和 tracked 文件精确 Key 扫描均为 0。 |
| 子进程清理 | Python/FFmpeg 调用有有界 timeout；超时用 `Task.shutdown(..., :brutal_kill)` 终止调用进程，正常/错误返回路径清理渲染临时目录；Worker 超时回归、全量 FFmpeg 和 E2E 渲染通过。 |
| 正式选择边界 | Timeline 替换只接受 `shot:` SelectionDecision，参考图不会出现在替换下拉或进入镜头；新增回归先失败后通过。 |
| 成本事实 | 所有真实提交先 estimate/reserve，再 settle；Provider 未返回货币金额时保存 `actual amount_micros=nil` 并在网页/脚本显示“未返回/unavailable”，不伪造 `$0`。 |

## PRD 逐条追踪

下表每行同时给出已检查的实现入口和直接执行过的测试/验收证据；“完成”不是仅由相邻需求推断。

| ID | 状态 | 实现证据 | 直接测试/验收证据 |
|---|---|---|---|
| FR-001 | 完成 | `Projects`、ProjectIndexLive 的创建/打开/重命名/归档 | `ProjectsTest`、`ProjectIndexLiveTest` |
| FR-002 | 完成 | `ProductionProfile`、Project 更新与单集 snapshot override | `ProjectsTest`、`RevisionsTest`、设置 LiveView 测试 |
| FR-003 | 完成 | `ConfigResolver` 实现 system → project → task；Project 设置页可编辑 | `ConfigResolverTest`、`ProjectsTest`、设置 LiveView 测试 |
| FR-004 | 完成 | `Prompts.Catalog/Composer` 分离隐藏 CorePrompt 与追加式 PromptAppendix | `ComposerTest`、`ImagePromptProposalTest`、设置 LiveView 不泄露 CorePrompt 断言 |
| FR-005 | 完成 | 中文权威输入保存在 Revision/Spec；`ImagePromptCompiler` 只编译 Provider prompt | `CompilerTest`、`ImagePromptProposalTest`、真实中文烟测 |
| FR-010 | 完成 | `Sources.Parser` 支持 UTF-8 TXT/MD/Markdown/文本 PDF | `ParserTest`、`SourcesTest`、AT-003 |
| FR-011 | 完成 | `SourceDocument/SourceRevision` 追加修订、hash、页码/offset locator | `SourcesTest`、`SourceAnalysisTest` |
| FR-012 | 完成 | 整本预检、文本层检查、`document_too_large` 稳定错误 | `ParserTest`、`SourceAnalysisTest` |
| FR-020 | 完成 | 3 个独立根及 required descendants 的持久化分析 DAG/Runner | `Analysis.DAGTest`、AT-003、真实 6 节点烟测 |
| FR-021 | 完成 | 严格 JSON Schema、领域 Validator、最多两次结构化修复 | `ValidatorTest`、`DAGTest`、AT-004 |
| FR-022 | 完成 | 输出强制 provenance 与零基 Unicode offset locator | `ValidatorTest`、`SourceAnalysisTest` |
| FR-030 | 完成 | `Narrative.materialize_episode` 从明确候选创建 Draft | `NarrativeTest`、Fake AT-001、LiveView 选择测试 |
| FR-031 | 完成 | Draft 可编辑；确认生成不可变 Revision 与输入/profile snapshot | `RevisionsTest`、LiveView 人工门测试 |
| FR-032 | 完成 | ShotPlan 确认后由 `Directing.Compiler` 确定性生成冻结 Spec | `CompilerTest`、Fake AT-001、真实 AT-005 |
| FR-040 | 完成 | Narrative → VisualDesign → ReferenceSet → ShotKeyframe 四层引用链 | `VisualsTest`、`CompilerTest`、AT-005/AT-006 |
| FR-041 | 完成 | 关键/常驻对象自动要求 overall、face/detail 等必需槽位 | `VisualsTest`、`ReferenceWorkflowTest`、真实 3 参考图断言 |
| FR-042 | 完成 | ReferenceWorkflow/Visuals 生成逐槽位候选并由明确选择冻结 ReferenceSet | `ReferenceWorkflowTest`、参考图 LiveView 测试、AT-005 |
| FR-043 | 完成 | 上传图与 AI 图统一 finalize 为内容寻址 AssetVersion | `AssetsTest`、`AssetsChangesTest`、AT-006 |
| FR-050 | 完成 | Fake/OpenAI 共用 Orchestrator；OpenAI Responses 与 Images adapters | adapter 单测、`OrchestratorInvariantsTest`、真实 AT-005 |
| FR-051 | 完成 | 系统默认参考图 4、镜头 2；Project/Task 可覆盖且必须为正整数 | `ReferenceWorkflowTest`、`ConfigResolverTest`、`ProjectsTest` |
| FR-052 | 完成 | GenerationSpec 区分 exploratory/formal；正式 Timeline 拒绝探索资产 | `OrchestratorInvariantsTest`、`TimelineTest` |
| FR-053 | 完成 | 图像编辑创建带 parent/reference/mask lineage 的新资产版本，不覆盖原图 | `OpenAIImagesTest`、参考图 LiveView 不可变编辑测试、AT-006 |
| FR-060 | 完成 | `TechnicalQC` 确定性探测 + `SemanticQC` Terra 多模态评价 | 两类 QC 单测、Fake AT-001、真实 AT-005 |
| FR-061 | 完成 | 语义报告按 Spec、ReferenceSet、相邻选择输出维度和证据 | `SemanticQCTest`、真实 9 份语义报告 |
| FR-062 | 完成 | 仅损坏/不可解码/硬规格失败阻断；语义失败可由用户明确接受 | `TechnicalQCTest`、`SemanticQCTest`、选择测试 |
| FR-063 | 完成 | Orchestrator 持久化 Attempt/QC/成本；候选卡显示证据且不默认选择 | `OrchestratorInvariantsTest`、CandidateGallery LiveView 测试、E2E |
| FR-070 | 完成 | `Changes.preview/confirm` 冻结 diff、依赖图 epoch 和选择范围 | `ChangesTest`、AT-007 |
| FR-071 | 完成 | stale 历史选择保留；可 pin old 或 replace；预览与正式门分离 | `ChangesTest`、`TimelineRestoreTest`、AT-009 |
| FR-072 | 完成 | 改选只调度当前/前一/后一镜头的精确 Selection ID 语义 QC | `SemanticQCTest`、`ChangesTest` |
| FR-073 | 完成 | 未提交旧工作取消；已提交 Attempt 按旧输入结算并标 stale | `ChangesTest`、AT-007 |
| FR-074 | 完成 | ChangeSet/NodeRun 部分成功保留，resume 不重复成功节点或费用 | `ChangesTest`、`WorkflowTest`、AT-007 |
| FR-080 | 完成 | Timeline 按 ShotPlan 组装，占位、重排、替换、增删均落库 | `TimelineTest`、Timeline LiveView 测试、E2E |
| FR-081 | 完成 | preferred duration、越界 warning、static/push/pull/four pan 编辑 | `TimelineTest`、`RenderIntegrationTest` |
| FR-082 | 完成 | hard cut 与有界 cross-dissolve，确定性 recipe | `TimelineTest`、`RenderRecipeTest` |
| FR-083 | 完成 | 逐句 SubtitleCue 独立编辑并冻结来源/时间/样式；UTF-8 SRT | `TimelineTest`、`RenderRecipeTest`、E2E |
| FR-084 | 完成 | 正式 Animatic 写入全时长 AAC 双声道静音占位轨 | `RenderIntegrationTest`、AT-008、真实 FFprobe |
| FR-085 | 完成 | 低清 preview 与冻结后 1080×1920 formal 分离、缓存和独立 QC | `RenderRecipeTest`、`RenderIntegrationTest`、AT-008/AT-009 |
| FR-090 | 完成 | estimate → reservation → actual 成本账；未知 actual 保持 nil | `CostsTest`、Provider/QC 回归、真实 33 条 actual |
| FR-091 | 完成 | 仅保存 credential reference；运行时从 Git 忽略 `.env` 解析 Key | adapter 单测、backup manifest 测试、真实与仓库 secret scan |
| FR-092 | 完成 | PostgreSQL 为事实源；Oban/Job 只携带记录 ID；可从记录恢复 | `WorkflowTest`、Fake 故障恢复、`BackupRestoreTest`、E2E |
| AT-001 | 完成 | Fake 三镜头端到端生产闭环 | `Acceptance.FakeMVPTest`、Playwright E2E |
| AT-002 | 完成 | 重复提交/乱序回调只落一份结果和费用 | `FakeMVPTest` AT-002、LiveView 故障控制、E2E |
| AT-003 | 完成 | TXT/MD/文本 PDF 全文导入、DAG 阻塞/恢复、来源定位 | `SourceAnalysisTest`、Parser/Sources 测试 |
| AT-004 | 完成 | 结构化非法输出追加修复 Attempt，成功或稳定失败 | `DAGTest`、`ValidatorTest` |
| AT-005 | 完成 | OpenAI 文本、AI 提示词、图像、语义 QC 与正式视频真实闭环 | `RealProviderSmokeTest` 2 passed，33 requests/IDs |
| AT-006 | 完成 | 上传资产和提示词图像编辑统一谱系且原版本不变 | `AssetsChangesTest`、OpenAI Images、LiveView 编辑测试 |
| AT-007 | 完成 | 精确 ChangeSet 影响面、无隐藏付费生成、局部 resume | `AssetsChangesTest`、`ChangesTest` |
| AT-008 | 完成 | Timeline/SRT/Preview/Formal 配方、编解码和下载 | `TimelineRestoreTest`、Render integration、E2E |
| AT-009 | 完成 | unresolved stale 阻止 formal，pin old 后按精确旧闭包导出 | `TimelineRestoreTest`、`TimelineTest` |
| AT-010 | 完成 | DB dump + AssetStore + manifest 恢复后一致且配方可重建 | `BackupRestoreTest` 与 2026-07-15 独立库实操演练 |

## 已知范围边界

- 本版本不实现认证、权限、租户隔离、RightsGate、内容安全工作台、真实视频、配音、音乐或发布。
- Suno 接口尚未接入；正式 Animatic 使用显式静音轨。后续 Provider 可沿现有 RequestSnapshot/Attempt/Cost/Asset/QC 合同加入，不需要推翻当前闭环。
- 图像遮罩编辑的领域合同与 lineage 已保留，首版网页只开放提示词编辑。
- Provider 不返回货币费用时，系统只能展示 usage 与“实际费用未返回”，不会猜测金额。

## 运行交接

- 测试地址：`http://127.0.0.1:4000/`
- `scripts/dev.ps1` 监督 PID：`78396`；Phoenix/BEAM 监听 PID：`39516`（Unicode PDF 修复后重启）。
- 当前 Provider 模式：`fake`（`.env` 未显式设置 `DRAMATIZER_PROVIDER` 时的默认值）；真实 OpenAI 闭环已由上面的 `-Force` 门禁验证。若要让网页实际计费调用 OpenAI，在 `.env` 设置 `DRAMATIZER_PROVIDER=openai` 后重启服务。
- 标准输出：`output/runtime/dev.stdout.log`；标准错误：`output/runtime/dev.stderr.log`。错误日志当前只含 Docker Compose healthy 状态，没有 Phoenix 异常。
- 最终直接 HTTP 探测返回 200；Playwright CLI 页面标题为“短剧制作台 · AI 短剧制作台”，可见项目创建和小说导入引导。截图：`output/playwright/persistent-home.png`。
- 根目录 `.env` 是本机配置且不提交；运行日志、截图、真实生成素材和烟测数据库均由 Git 忽略。

## 交接结论

- `feat/dramatizer-mvp` 已推送并设置为跟踪 `origin/feat/dramatizer-mvp`；本次 PDF 修复提交后再次核对本地和远端对象 ID。
- worktree 保留，不执行合并或清理，便于用户直接测试和后续迭代。
- 当前没有未解决的功能、测试或外部配置阻塞。
