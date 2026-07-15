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
