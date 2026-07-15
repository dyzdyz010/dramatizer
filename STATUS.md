# Dramatizer 当前状态

**检查点日期：** 2026-07-15

**当前分支：** `feat/dramatizer-mvp`（隔离 worktree：`.worktrees/dramatizer-mvp`）

**工作阶段：** Task 1–14 已提交；Task 15 Fake 端到端闭环已实现并通过浏览器验收，正在执行阶段全量门禁

## 当前事实

- `docs/ai_short_drama_framework_v0.2/` 是已经冻结并通过跨模型审计的原始实施基线。
- 当前方向已变为本机、单用户、无认证/权限/权利安全子系统的功能优先版本。
- 已确认的增量决策记录在 [`docs/implementation-alignment.md`](docs/implementation-alignment.md)。
- 对齐记录目前包含 `D-001` 至 `D-059`；最新确认批次是静态 Animatic 时间线、字幕、静音占位与双路径导出。
- 完整产品需求与实施设计已整理并确认为实施基线：[`docs/superpowers/specs/2026-07-15-dramatizer-mvp-prd.md`](docs/superpowers/specs/2026-07-15-dramatizer-mvp-prd.md)。
- 逐文件、逐测试的执行清单位于 [`docs/superpowers/plans/2026-07-15-dramatizer-mvp.md`](docs/superpowers/plans/2026-07-15-dramatizer-mvp.md)。
- Phoenix/LiveView 应用、PostgreSQL/Oban、本地 AssetStore、全文 parser、分析 DAG、Revision/ChangeSet、Fake/OpenAI Provider 合同、图像 QC、时间线、字幕、FFmpeg 导出和备份恢复已按 Task 1–14 提交。
- Task 15 新增 AT-001–AT-004、AT-006–AT-010 命名验收测试和 Playwright Chromium 全流程；真实浏览器上传采用自动上传、进度可见和空提交保护。

## 最新验证证据

- `mix.bat format --check-formatted` 与 `mix.bat compile --warnings-as-errors`：通过。
- `./scripts/test.ps1`：85 passed（105.3s），包含单元、集成、命名验收、LiveView 和真实 FFmpeg 正式导出。
- `mix.bat test test/dramatizer/acceptance test/dramatizer_web/live/project_workspace_live_test.exs`：14 passed，作为 Task 15 focused gate。
- `mix.bat test test/dramatizer/acceptance`：7 passed，覆盖离线 AT 与 TimelineClip → SourceRevision 全血缘。
- `./scripts/e2e.ps1`：1 passed（50.8s）；完成三 Shot Fake 制作闭环、人工确认、候选选择、字幕编辑、预览/正式导出、全部阶段路由、素材 HTTP、失败恢复和重复/乱序回调去重。
- v0.2 合同校验：8 schemas、7 mapped examples、33 negative cases 与全部本地 Markdown 链接通过；`git diff --check` 通过。
- E2E 正式视频经 FFprobe 验证为 1080×1920、H.264、yuv420p，并包含 AAC 双声道静音轨；MP4/SRT 均通过应用路由下载。
- Task 14 已实际执行备份与恢复到全新数据库/素材根，并在恢复后通过 manifest 一致性检查。

## 已对齐的关键方向

- Localhost Web 应用；Phoenix + Ecto + Oban + LiveView；PostgreSQL + 本地文件系统 AssetStore。
- 多 Project，但无用户、认证、RBAC/ABAC 或租户安全边界。
- 删除 RightsGate、waiver、许可和安全子系统；保留 Revision、状态机、幂等、资产 finalize、成本、QC 和人工选择。
- 首个闭环为 1 集、1 场、3 Shot 的 Fake Provider 可恢复流水线；Fake 与真实 Provider 共用执行路径。
- 首批真实能力为 OpenAI 文本与图像：`gpt-5.6-terra` 默认文本分析、`gpt-5.6-sol` 可用于高要求任务覆盖、`gpt-image-2` 生成图像。
- 小说入口支持 UTF-8 TXT、Markdown 和文本 PDF；首版采用整本输入、多任务调用和显式分析 DAG。
- AI 输出先进入 Draft/Proposal；用户确认后才形成不可变 Revision。
- CorePrompt 对用户隐藏且不可修改；PromptAppendix 按任务类型允许用户编辑。
- 正式图像生产采用“文本设定 Revision → VisualDesignRevision → ReferenceSetRevision → ShotKeyframe”四层链路。
- 常驻角色及跨镜头/剧情关键的场景、道具必须先确认参考图；一次性普通对象允许只用文本。
- 用户上传图与 AI 生成图共用 AssetVersion 路径；参考资产默认 4 个候选，逐镜分镜默认 2 个候选。
- 首版支持提示词图像编辑，遮罩编辑保留合同但推迟 UI；编辑与重生成永不覆盖原资产。
- 静态图像候选默认执行确定性技术 QC 和一次 GPT-5.6 Terra 多模态语义 QC；首版不引入专用 CV 模型。
- 只有损坏、不可解码或违反硬媒体规格的确定性失败阻断选择；语义 QC 只提供证据和建议，用户保留最终选择权。
- ShotKeyframe 语义 QC 对照精确 GenerationSpec、ReferenceSet 和存在时的相邻已选镜头；不会把整集图片全部塞进每次检查。
- QC 不自动触发付费重生成；用户可重生成、提示词编辑、接受结果或返回上游确认新 Revision。
- 上游新 Revision 先形成影响预览 ChangeSet；用户选择升级范围后自动增量重编译，但不自动发起付费图片生成。
- stale 主图保持原选择；用户可继续固定旧输入或升级重生成。工作预览允许带 stale 继续，正式导出前必须逐项解决。
- 改选 Shot 主图只自动重跑该 Shot 与直接邻居的语义 QC；不会重跑整集或自动重生成图片。
- ChangeSet 按节点保留部分成功并可恢复；未外发旧任务会取消，已外发任务继续对账且结果按旧输入标记 stale。
- 首条 Timeline Draft 按 ShotPlan 自动组装并允许重排；Clip 默认使用 preferred duration，但越界只警告、不反向修改导演 Revision。
- 静态关键帧支持有限运动预设；镜头默认硬切并可选简单叠化；对白生成独立句级字幕轨。
- 文本与图像阶段不接真实音频 Provider，正式 Animatic 使用显式 AAC 静音占位轨。
- Timeline Draft 可生成低清预览；冻结 TimelineVersion 后生成正式 H.264/AAC MP4 并执行独立导出 QC。

## 续接步骤

```powershell
git pull origin main
pwsh -NoProfile -File .\docs\ai_short_drama_framework_v0.2\tools\validate_contracts.ps1
```

然后先读：

1. 本文件；
2. [`docs/implementation-alignment.md`](docs/implementation-alignment.md)；
3. [`docs/superpowers/specs/2026-07-15-dramatizer-mvp-prd.md`](docs/superpowers/specs/2026-07-15-dramatizer-mvp-prd.md)；
4. [`docs/ai_short_drama_framework_v0.2/docs/11_roadmap_and_acceptance.md`](docs/ai_short_drama_framework_v0.2/docs/11_roadmap_and_acceptance.md)。

PRD 已确认。实现阶段不再发起细节问卷；严格按冻结计划执行。仅在 API Key、管理员权限、外部服务授权或产品范围冲突等必须由用户处理的硬阻塞处暂停。

## 下一步

1. 完成 Task 15 规定的全量 ExUnit、合同校验和差异检查并提交 `test: prove fake MVP end to end`。
2. 进入 Task 16，仅检查 `OPENAI_API_KEY` 是否存在；如果根目录 `.env` 和进程环境均没有 Key，则在此门槛暂停，请用户自行写入，绝不回显。
3. 真实 OpenAI 文本/图像/QC 有界烟测通过后执行 Task 17 全量复核、推送并把 `http://127.0.0.1:4000/` 留在后台供实际验收。
