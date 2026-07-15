# 备份与恢复运行手册

备份单元是同一检查点下的 PostgreSQL custom dump、content-addressed AssetStore 和非敏感 manifest。不要只复制数据库或只复制 `var/assets`。

## 创建备份

1. 停止 Phoenix；备份脚本检测到端口仍在监听会拒绝继续。
2. 执行：

```powershell
./scripts/backup.ps1
```

也可指定目录：

```powershell
./scripts/backup.ps1 -Destination D:\backups\dramatizer-20260715
```

脚本建立 `var/write-checkpoint.json`，先执行 AssetStore 一致性检查，再通过 `dramatizer-postgres` 容器运行 `pg_dump`，复制 `assets/final` 并生成 `manifest.json`。成功或失败退出时都会明确解除检查点。

## 恢复

恢复会替换目标数据库和 AssetStore，因此必须显式提供 `-Force`，且 Phoenix 必须已停止：

```powershell
./scripts/restore.ps1 `
  -Source D:\backups\dramatizer-20260715 `
  -TargetAssetRoot D:\dramatizer-restored-assets `
  -Force
```

脚本终止数据库连接、重建目标数据库、执行 `pg_restore`、替换经过绝对路径校验的目标 AssetStore，并运行 `mix dramatizer.assets.verify`。验证通过后才解除停写检查点。

## 故障判断

- `missing`：数据库引用存在，但 blob 不存在；不得继续正式导出。
- `corrupt`：大小或 SHA-256 不匹配；从同一备份重新恢复。
- `orphan`：final blob 没有数据库/manifest 引用；先调查，不自动删除。
- manifest 只记录凭据引用名和模型配置，不保存 API Key、Authorization、密码或 token 值。
