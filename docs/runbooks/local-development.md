# 本地开发运行手册

## 首次准备

1. 将 `.env.example` 复制为根目录 `.env`。默认 `DRAMATIZER_PROVIDER=fake`，不需要 API Key。
2. 安装 Docker Desktop、Elixir/OTP、FFmpeg、Python。
3. 在仓库根目录运行 `./scripts/setup.ps1`。

## 启动

运行：

```powershell
./scripts/dev.ps1
```

脚本只监听 `127.0.0.1`，启动 PostgreSQL、执行迁移和资源构建，再运行 Phoenix。默认地址是 `http://127.0.0.1:4000`。终端只输出服务地址和 Provider 模式，不输出 `.env` 或凭据值。

如果 `var/write-checkpoint.json` 存在，说明备份或恢复正在停写；完成或处理该操作后才能启动。

## 日常验证

```powershell
./scripts/test.ps1
Push-Location app
mix.bat dramatizer.assets.verify
Pop-Location
```

真实 Provider 验证只通过 `scripts/real-smoke.ps1` 进行；普通开发和 E2E 保持 Fake，避免意外成本。

## 真实 OpenAI 烟测

根目录 `.env` 或当前进程必须提供 `OPENAI_API_KEY`，并将 `.env` 保持在 Git 忽略范围内。脚本只打印 Key 是否存在，不打印值：

```powershell
./scripts/real-smoke.ps1
```

脚本使用独立数据库 `dramatizer_real_smoke`、`var/real-smoke-assets/` 和 `output/real-smoke/`，不污染普通测试数据库和正式素材目录。默认会复核最近一次已通过的忽略目录证据，避免重复产生 Provider 成本；需要重新发起全部真实请求时显式运行：

```powershell
./scripts/real-smoke.ps1 -Force
```

有界真实门禁固定执行 6 个全文分析节点、3 张必需角色参考图、每个 3 Shot 的 2 张候选、技术/语义 QC、显式候选选择和 1080×1920 正式 Animatic。文本与语义 QC 使用 `gpt-5.6-terra`，图像使用 `gpt-image-2`。请求快照保存模型、配置/提示词/Schema 哈希、Provider request ID 和原始 usage map；不保存 Authorization header 或 Key。Provider 未返回货币成本时，状态记录为“不可用”，不得把它解释为零成本。

若传输层出现一次 `provider_unavailable`、`provider_timeout` 或 `rate_limited`，烟测只对失败的分析 Node 做一次显式续跑；结构校验、凭据、额度或组织验证错误不会自动重试。GPT Image 账号可能需要在 OpenAI 控制台完成组织验证，相关要求以 [OpenAI 图像生成指南](https://developers.openai.com/api/docs/guides/image-generation) 为准。
