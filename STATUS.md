# Dramatizer 当前状态

**检查点日期：** 2026-07-14

**当前分支：** `main`

**工作阶段：** 单用户实施设计对齐，尚未开始应用脚手架或业务代码实现

## 当前事实

- `docs/ai_short_drama_framework_v0.2/` 是已经冻结并通过跨模型审计的原始实施基线。
- 当前方向已变为本机、单用户、无认证/权限/权利安全子系统的功能优先版本。
- 已确认的增量决策记录在 [`docs/implementation-alignment.md`](docs/implementation-alignment.md)。
- 对齐记录目前包含 `D-001` 至 `D-031`；最后确认项是 Provider 调用无状态。
- 本轮对齐尚未结束，不能据现有记录直接推定所有模块设计已经完成。

## 已对齐的关键方向

- Localhost Web 应用；Phoenix + Ecto + Oban + LiveView；PostgreSQL + 本地文件系统 AssetStore。
- 多 Project，但无用户、认证、RBAC/ABAC 或租户安全边界。
- 删除 RightsGate、waiver、许可和安全子系统；保留 Revision、状态机、幂等、资产 finalize、成本、QC 和人工选择。
- 首个闭环为 1 集、1 场、3 Shot 的 Fake Provider 可恢复流水线；Fake 与真实 Provider 共用执行路径。
- 首批真实能力为 OpenAI 文本与图像：`gpt-5.6-terra` 默认文本分析、`gpt-5.6-sol` 可用于高要求任务覆盖、`gpt-image-2` 生成图像。
- 小说入口支持 UTF-8 TXT、Markdown 和文本 PDF；首版采用整本输入、多任务调用和显式分析 DAG。
- AI 输出先进入 Draft/Proposal；用户确认后才形成不可变 Revision。
- CorePrompt 对用户隐藏且不可修改；PromptAppendix 按任务类型允许用户编辑。

## 下一台电脑的续接步骤

```powershell
git pull origin main
pwsh -NoProfile -File .\docs\ai_short_drama_framework_v0.2\tools\validate_contracts.ps1
```

然后先读：

1. 本文件；
2. [`docs/implementation-alignment.md`](docs/implementation-alignment.md)；
3. [`docs/ai_short_drama_framework_v0.2/docs/11_roadmap_and_acceptance.md`](docs/ai_short_drama_framework_v0.2/docs/11_roadmap_and_acceptance.md)。

继续使用逐项 grilling：每确认一个决策，先更新 `docs/implementation-alignment.md`，再问下一项。

## 下一项建议问题

图像生产 DAG 是否固定为：先确认 Character/Location/Prop Visual Revision 和参考图，再生成引用这些精确版本的 Shot 关键帧候选？

后续仍需对齐的主要分支包括：图像一致性与参考资产、候选与 QC、局部重生成、时间线与导出、SourceDocument 替换后的 stale 传播、备份/恢复，以及分阶段验收。
