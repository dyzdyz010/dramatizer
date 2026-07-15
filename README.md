# Dramatizer

本机单用户的 AI 短剧制作台。当前 MVP 已实现从 TXT、Markdown、文本型 PDF 小说全文导入，到分析、分集、视觉权威、参考图、三镜头关键帧、字幕时间线和 H.264/AAC Animatic 导出的可追溯闭环。默认使用 Fake Provider，可离线验证完整生产合同，不需要登录、权限或 API Key。

## 本机运行

需要 Docker Desktop、Elixir/OTP、Python 与 FFmpeg。首次准备：

```powershell
Copy-Item .env.example .env
./scripts/setup.ps1
```

启动制作台：

```powershell
./scripts/dev.ps1
```

浏览器打开 `http://127.0.0.1:4000/`。默认 `DRAMATIZER_PROVIDER=fake`；素材保存在 `var/assets`，PostgreSQL 只监听本机 `127.0.0.1:55432`。

## 验证与运维

```powershell
./scripts/test.ps1
./scripts/e2e.ps1
./docs/ai_short_drama_framework_v0.2/tools/validate_contracts.ps1
```

- `test.ps1`：ExUnit 单元、集成和验收测试。
- `e2e.ps1`：在独立数据库、独立素材目录和 4100 端口运行真实 Chromium 全流程，验证 MP4/SRT 下载与 FFprobe，不污染开发库。
- `backup.ps1` / `restore.ps1`：带写入检查点、数据库 dump、AssetStore manifest 和恢复后一致性校验的本地备份恢复。

详细操作见 [`docs/runbooks/local-development.md`](docs/runbooks/local-development.md) 与 [`docs/runbooks/backup-restore.md`](docs/runbooks/backup-restore.md)。

## 设计与进度

- 当前 PRD：[`docs/superpowers/specs/2026-07-15-dramatizer-mvp-prd.md`](docs/superpowers/specs/2026-07-15-dramatizer-mvp-prd.md)
- 冻结实施计划：[`docs/superpowers/plans/2026-07-15-dramatizer-mvp.md`](docs/superpowers/plans/2026-07-15-dramatizer-mvp.md)
- 当前检查点：[`STATUS.md`](STATUS.md)
- 原始冻结架构基线：[`docs/ai_short_drama_framework_v0.2/README.md`](docs/ai_short_drama_framework_v0.2/README.md)

真实 OpenAI 文本、图像和语义 QC 使用同一生产路径，但只通过有成本上限的 `scripts/real-smoke.ps1` 验证；普通开发与 E2E 始终强制 Fake，避免意外付费。
