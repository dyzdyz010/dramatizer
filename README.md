# Dramatizer

面向 AI 视频与连续短剧生产的架构设计项目，目标是建立可追溯、可恢复、可审计且 Provider-neutral 的生产框架。

## 设计版本

- [`v0.2`](docs/ai_short_drama_framework_v0.2/README.md)：当前实施基线，包含 12 章设计、8 个 JSON Schema、7 组示例、4 张架构图、契约验证和跨模型审计记录。
- [`v0.1`](docs/ai_short_drama_framework_v0.1/README.md)：早期顶层设计与原始设计文档。

## 验证 v0.2

在 PowerShell 7 中运行：

```powershell
./docs/ai_short_drama_framework_v0.2/tools/validate_contracts.ps1
```

验证覆盖 Draft 2020-12 Schema、合法示例、关键非法反例和本地 Markdown 链接。设计包文件完整性可通过 [`manifest.sha256`](docs/ai_short_drama_framework_v0.2/manifest.sha256) 核验。

## 当前状态

v0.2 已完成 Codex/GPT 与 Claude 的跨模型架构审计，当前没有未解决的 P0/P1 设计缺陷。真实 Provider、对象存储、数据库事务约束和发布平台行为仍须按路线图通过 Spike 与契约测试验证。
