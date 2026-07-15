# Dramatizer 当前状态

**检查点日期：** 2026-07-15

**当前分支：** `main`

**工作阶段：** 单用户 MVP PRD 已整理，等待用户审阅；尚未开始应用脚手架或业务代码实现

## 当前事实

- `docs/ai_short_drama_framework_v0.2/` 是已经冻结并通过跨模型审计的原始实施基线。
- 当前方向已变为本机、单用户、无认证/权限/权利安全子系统的功能优先版本。
- 已确认的增量决策记录在 [`docs/implementation-alignment.md`](docs/implementation-alignment.md)。
- 对齐记录目前包含 `D-001` 至 `D-059`；最新确认批次是静态 Animatic 时间线、字幕、静音占位与双路径导出。
- 完整产品需求与实施设计已整理到 [`docs/superpowers/specs/2026-07-15-dramatizer-mvp-prd.md`](docs/superpowers/specs/2026-07-15-dramatizer-mvp-prd.md)，当前等待用户审阅。

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

继续使用分批调查问卷：每批只收敛一个设计分支；收到提交确认后，先更新 `docs/implementation-alignment.md`，再发布下一批问卷。

用户已要求停止逐项确认实现细节。后续由设计过程直接确定可从既有不变量推导的默认值，只对产品范围、核心流程、架构方向和 MVP 边界继续提问。

## 下一步

用户审阅并确认 MVP PRD。若需要调整，先更新 PRD 与对齐记录并重新做一致性检查；确认后编写详细实施计划，再开始 Phase 0 应用脚手架与合同地基。
