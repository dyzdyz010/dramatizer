# Dramatizer 当前状态

**检查点日期：** 2026-07-21

**当前分支：** `feat/dramatizer-mvp`（隔离 worktree：`.worktrees/dramatizer-mvp`）

**工作阶段：** MVP Task 1–17 与 production-workspace-v2 Task 1–9 全部完成；Fake 与真实 OpenAI 双路径门禁全绿；系统留在本机供创作使用

## 当前产品化状态

- D-060 方案 A 已落地：分阶段持久工作台（来源/分析/分集/视觉/镜头/时间线/运行记录）＋每阶段真实 AI Proposal（`narrative_proposal`、`visual_design_proposal`、`directing_proposal`）＋领域表单确认。
- Narrative、VisualDesign、ShotPlan 与模型覆盖均通过结构化表单编辑；浏览器 E2E 断言页面不存在裸 JSON 编辑面。
- 工作台外壳为顶部 Provider/模型状态栏、左侧阶段栏、主画布、右侧 Inspector 诊断层与底部下一步条；Provider 徽标始终显示“Fake 模拟模式”或“OpenAI 已启用”。
- 阶段内自动推进到下一个人工门：付费图像生成、Revision 确认、主图选择与正式导出必须显式触发。

## 当前事实

- 产品是本机、单用户、多 Project、无登录/认证/RBAC/权利安全子系统的功能优先制作台。
- 冻结需求是 [`docs/superpowers/specs/2026-07-15-dramatizer-mvp-prd.md`](docs/superpowers/specs/2026-07-15-dramatizer-mvp-prd.md)；工作台设计是 [`docs/superpowers/specs/2026-07-15-production-workspace-v2-design.md`](docs/superpowers/specs/2026-07-15-production-workspace-v2-design.md)；历史对齐决策是 [`docs/implementation-alignment.md`](docs/implementation-alignment.md)（D-001 至 D-060）。
- Phoenix/LiveView、PostgreSQL/Oban、本地内容寻址 AssetStore、全文 Parser、分析 DAG、Draft/Revision、三类阶段 Proposal、视觉权威、Fake/OpenAI Provider、两层 QC、ChangeSet/stale、Timeline/字幕、FFmpeg 和本地备份恢复在同一持久化闭环。
- 真实路径由 `gpt-5.6-terra` 完成结构化分析、三类阶段 Proposal、图像提示词补全和多模态语义 QC，`gpt-image-2` 完成图像生成/编辑；Fake 与 OpenAI 共用 GenerationSpec、ProviderRequestSnapshot、Attempt、CostEntry、AssetVersion、QC、SelectionDecision 与 TimelineVersion。
- `DRAMATIZER_PROVIDER` 只接受 `fake`/`openai`：未知取值在启动阶段拒绝（`config.exs` 与 `scripts/dev.ps1` 双重校验），`openai` 缺少 `OPENAI_API_KEY` 同样拒绝启动，不存在静默回退。
- 普通 `mix test` 在 test 配置中钉死 Fake（无论 `.env` 如何设置），只有显式 `DRAMATIZER_REAL_SMOKE=1` 的真实门禁保留环境模式；付费路径无法被隐式触发。
- OpenAI adapters 尊重标准 `HTTPS_PROXY`/`HTTP_PROXY` 环境变量（BEAM 不会自动读取；本机必须经本地代理访问 Provider，curl 可通而 BEAM 直连不通的形态已复现并修复）。

## 2026-07-21 fresh gate

- `mix.bat format --check-formatted`、`mix.bat compile --warnings-as-errors`、`mix.bat assets.build`：全部通过。
- `./scripts/test.ps1`：最终 **120 passed，1 excluded**（含本轮新增的跨节点引用与分集 kind 回归）；在 `.env` 切到 `DRAMATIZER_PROVIDER=openai` 后重跑保持全绿（test 环境 Fake 钉死生效）。
- `./scripts/e2e.ps1`：Chromium **1 passed**；覆盖项目创建、模型覆盖表单、小说上传自动进入分析、六节点 DAG、分集选择自动生成 Narrative 草稿、确认冻结自动生成 VisualDesign 提案、AI 参考候选与逐槽位主图选择、ReferenceSet 冻结自动生成 Directing 提案、连续性、Spec 编译、候选生成/QC/选择、字幕编辑、预览、正式导出、MP4/SRT 下载与 FFprobe 校验、失败注入恢复、全阶段路由，以及“页面无裸 JSON 编辑面”断言。
- v0.2 合同校验：**8 schemas、7 mapped examples、33 negative cases** 与全部本地 Markdown 链接通过。
- `./scripts/real-smoke.ps1 -Force`：**PASS**。Proposal 驱动的真实闭环完成 **6 个分析节点、3 类阶段 Proposal、8 张参考图（1 角色/1 场景/1 道具 × 模板槽位）、6 张镜头候选（3 Shot × 2）、14 份技术 QC、14 份 Terra 语义 QC、3 个最终 Clip**；持久化 **49 个 ProviderRequestSnapshot、48 个 Provider request ID**；usage **220,027 total tokens**（166,126 input / 53,901 output，含 1,540 output image tokens）。API 未返回币种费用，49 条 actual 记录金额如实为 `unavailable`。
- 正式输出经 FFprobe 验证为 **1080×1920、H.264、yuv420p、AAC 双声道静音轨**；最终 Clip 可回溯到 Asset/QC/Attempt/RequestSnapshot/GenerationSpec/ShotPlan/Visual/Narrative/Source。
- 烟测成本控制：三类 Proposal 挂 PromptAppendix 规模约束；测试在确认前对 Draft 执行编辑裁剪（每类型 1 对象、每对象 1 variant、槽位归一 visual-slots-v1 模板、镜头取前 3），这一步复用产品的草稿编辑 API，与用户手工收敛行为一致。

## 本轮闭合的真实路径缺口

按“先 RED 后修复”的顺序，真实 Proposal 门禁暴露并闭合了以下缺口（全部有回归测试或脚本级断言）：

| 缺口 | 修复 | 证据 |
|---|---|---|
| BEAM 不读代理环境变量，本机直连 OpenAI 传输层失败 | 新增 `ProxyOptions`，两个 adapter 统一合并 `connect_options: [proxy: ...]` | BEAM 内 `/v1/models` 探测 200；真实门禁全通 |
| `conflict_check` 引用上游实体被判 `dangling_reference` | Validator 增加 `known_reference_ids`，运行时并入本 run 已成功节点的 item ID | `ValidatorTest` 跨节点引用用例；真实 6 节点通过 |
| 真实模型分集项 kind 为 `episode_candidate`，UI 与 proposal_authority 均要求 `episode`，会得到空候选列表 | CorePrompt 钉死 kind 契约；Validator 增加 `missing_episode_item` 域错误使偏差进入修复循环 | `ValidatorTest` 新用例；真实分集选择通过 |
| Orchestrator openai 路径新增提示词提案后，合同测试未提供 `prompt_submitter` 桩 | 合同测试补桩并断言 `image_prompt` 快照 | 非付费合同测试通过 |
| `real-smoke.ps1` 断言硬编码旧形状（3 参考图/9 QC/33 请求） | 改为边界＋一致性等式（QC=图像数、候选=2×Clip、请求数下限按幂等复用计算） | 复核模式对新证据 PASS |

## 已知范围边界

- 本版本不实现认证、权限、租户隔离、RightsGate、内容安全工作台、真实视频、配音、音乐或发布。
- Suno 接口尚未接入；正式 Animatic 使用显式 AAC 静音占位轨。后续 Provider 可沿现有 RequestSnapshot/Attempt/Cost/Asset/QC 合同加入。
- 图像遮罩编辑的领域合同与 lineage 已保留，首版网页只开放提示词编辑。
- Provider 不返回货币费用时，系统只能展示 usage 与“实际费用未返回”，不会猜测金额。
- 真实模型对 PromptAppendix 的规模约束遵守是概率性的：产品侧由用户在表单里编辑收敛，门禁侧由草稿裁剪保证确定性；两者都不改变“AI 只产生 Draft”的边界。

## 运行交接

- 测试地址：`http://127.0.0.1:4000/`
- `scripts/dev.ps1` 监督 PID：`33972`；Phoenix/BEAM 监听 PID：`72040`（2026-07-21 以 OpenAI 模式重启）。
- 当前 Provider 模式：`openai`（根目录 `.env` 已设置 `DRAMATIZER_PROVIDER=openai`）；工作台顶部显示“OpenAI 已启用”。网页操作会实际计费调用 OpenAI；若要回到离线模式，把 `.env` 改回 `DRAMATIZER_PROVIDER=fake` 后重启 `scripts/dev.ps1`。
- 2026-07-21 浏览器烟测：真实浏览器创建“浏览器烟测-1784622629671”项目并上传含 CJK 与 naïve/für/não 变音符文本的文本层 PDF（218 字、rev 1、页码 locator），常驻服务在 OpenAI 模式下自动完成 6 节点整本分析并生成 AnalysisSnapshot；分析页 6 节点全部 ready，截图：`output/playwright/openai-browser-smoke.png`。用户既有 `test` 项目未受影响。
- 标准输出：`output/runtime/dev.stdout.log`；标准错误：`output/runtime/dev.stderr.log`（当前无 Phoenix 异常）。
- 根目录 `.env` 是本机配置且不提交；运行日志、截图、真实生成素材和烟测数据库均由 Git 忽略。

## 交接结论

- production-workspace-v2 计划（Task 1–9）全部勾选完成；`feat/dramatizer-mvp` 已推送并跟踪 `origin/feat/dramatizer-mvp`。
- worktree 保留，不执行合并或清理，便于直接创作使用和后续迭代。
- 当前没有未解决的功能、测试或外部配置阻塞。用户可从 `http://127.0.0.1:4000/` 直接开始：创建项目 → 上传小说 → 自动分析 → 选择分集 → 按阶段确认 Narrative/视觉/镜头 → 生成并选择图像 → 编辑时间线与字幕 → 导出正式 Animatic。
