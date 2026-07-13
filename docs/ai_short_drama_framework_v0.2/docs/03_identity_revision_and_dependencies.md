# 3. 身份、Revision 与依赖合同

## 3.1 三种身份不能混用

| 名称 | 示例 | 可变性 | 用途 |
|---|---|---|---|
| logical ID | `ep01_sc03_sh05` | 稳定，不复用 | 表示“同一个逻辑对象” |
| revision ID | `rev_2c1c45b4-4f85-4f03-8ca9-7a3eb7cc5f0a` | 全局唯一且不可变 | 表示对象的一次确切内容版本 |
| head pointer | `(shot_plan_revision, ep01_sc03_sh05, main) → rev_...` | 受控可变 | 表示某条 stream 当前推荐的 Revision |

对象存储中的媒体还有 `content_hash`；它证明字节内容，不替代 Asset/AssetVersion 的业务身份。两个 AssetVersion 可以有相同内容哈希但不同许可、来源或业务角色。

logical ID 一经分配不得被另一个概念复用。重命名展示标题不改 logical ID。导入外部数据发生冲突时分配新 ID，并保存显式映射。

## 3.2 Revision 记录

所有权威 Revision 至少包含：

```text
logical_id
revision_id
revision_number
parent_revision_ids[]
created_at / created_by
change_summary
immutable payload
extensions[]
```

规则：

1. `revision_id` 由服务端产生，写入后整行不可更新；修正拼写也创建新 Revision。
2. `revision_number` 只要求在同一 logical ID 内唯一，供人阅读；它不是乐观锁。
3. 首个 Revision 的父列表为空；普通编辑有一个父；显式合并可以有两个父。
4. Revision DAG 必须无环，父必须属于同一 logical ID，且创建时间不得晚于子 Revision 的提交时间。
5. 服务器在提交前对规范化 payload 计算内容哈希；相同命令的重试返回既有 Revision，不重复编号。
6. 任何用于执行或发布的引用必须保存 revision ID。只保存 logical ID 的字段仅限搜索、导航和 head 管理。

## 3.3 Head pointer 与并发

Head pointer 独立于 Revision 保存，主键为：

```text
(entity_type, logical_id, stream_id)
```

`stream_id` 可以是 `main`、平台改编线或实验线。每条 stream 同时只有一个 head，但同一 logical entity 可以存在多个 stream。v0.2 不把“多个并列导演方案”伪装成同一 ShotPlan 的多个 head；若方案能被独立选择和排产，它们应有不同 ShotPlan logical ID。

移动 head 使用 compare-and-swap：

```text
expected_head_revision_id + expected_lock_version
→ validate candidate ancestry and permissions
→ update head_revision_id, increment lock_version
→ append audit event
```

如果 CAS 失败：

- 已创建的 Revision 仍然有效，不能删除；
- 客户端读取新 head，选择重基、三方合并、保留分支或放弃移动 head；
- 服务端不得以“最后写入者获胜”静默覆盖；
- 合并后的新 Revision 明确列出两个父 Revision。

Revision 插入、head CAS 和 outbox 事件写入应在同一数据库事务内。跨聚合影响计算异步执行，因此 UI 必须允许短暂显示 `impact_pending`，不能声称依赖已经检查完成。

## 3.4 精确引用合同

`VersionedRef` 总是同时携带：

```json
{
  "entity_type": "beat_revision",
  "logical_id": "ep01_sc03_b02",
  "revision_id": "rev_f1fe08c2-4c4c-4f8d-9709-b8f3c26814ba"
}
```

`ImmutableRef` 用于没有 logical + revision 双层身份的记录，例如 GenerationAttempt。服务在写入时验证引用存在、类型匹配、租户/项目边界匹配且调用者有权读取。

Schema 的 `entity_type` 是开放注册表中的类型标签，不意味着任意字符串都会被业务层接受。新类型必须先登记其所有者、ID 规则、删除策略和授权策略。

## 3.5 依赖边

依赖边方向固定为：

```text
dependent ──depends_on──> dependency
```

每条 `DependencyEdge` 包含精确 dependent、精确 dependency、依赖类别、跟踪模式、影响路径和创建时间。不得只保存“用了 char_lin”，必须保存“用了 char_lin 的哪个 Revision”。

依赖类别：

| kind | 含义 | 示例 |
|---|---|---|
| `semantic_input` | 权威叙事输入 | ShotPlanRevision → BeatRevision |
| `director_input` | 导演输入 | GenerationSpecRevision → ShotPlanRevision |
| `reference_asset` | 参考媒体 | GenerationSpecRevision → Character AssetVersion |
| `compiler_config` | 编译器或模板配置 | Spec → CompilerConfigRevision |
| `policy_input` | 路由、质量或连续性策略 | Spec/Decision → PolicyRevision |
| `evidence_input` | 决策所依据的证据 | ContinuityApproval → Observation |
| `timeline_source` | 时间线素材 | TimelineVersion → AssetVersion |

所有边必须由拥有 dependent 的服务创建。依赖服务不能反向修改 dependent。删除依赖时发出 revoked/tombstoned 事件，由图索引计算影响。

## 3.6 跟踪模式

精确引用保证重放；`tracking.mode` 决定“相对新 head 是否需要提示或重编译”：

| mode | head 前进后的规则 | 典型使用 |
|---|---|---|
| `pinned` | 不因 head 前进 stale；缺失、撤销或完整性失败仍会 stale | 已发布 Timeline、冻结基准 |
| `follow_head` | 比较绑定 Revision 与指定 stream 新 head 的累积差异 | 活跃 ShotPlan、尚未批准的 Spec |
| `approval_gated` | head 前进先为 `unknown`，经影响审核后转 fresh/stale | 已批准候选、临近发布的时间线 |

`impact_paths` 是 dependency payload 中会影响 dependent 的 JSON Pointer 前缀。`/` 表示任何变化都相关。编译器必须保存实际读取路径；无法证明精确读取范围时使用 `/`，不能为了减少重生成而猜测。

## 3.7 stale 判定

Staleness 是可重算的派生索引，不写回不可变 Revision 本体。状态只有：

- `fresh`：依赖存在且按跟踪规则没有相关变化；
- `stale`：至少一条依赖有确定的失效原因；
- `unknown`：影响计算尚未完成或 `approval_gated` 等待裁决。

确定性判定顺序：

1. 读取 dependent 的全部依赖边；任何依赖缺失、撤销或哈希校验失败，标记 stale。
2. `pinned` 边跳过 head 比较。
3. `follow_head` 边读取指定 stream 的 head。若仍是绑定 Revision，边 fresh。
4. 若 head 已变化，计算从绑定 Revision 到新 head 的累积结构化 diff；差异路径与任一 `impact_paths` 相交则 stale，否则该边 fresh。
5. `approval_gated` 发生 head 变化时先标 unknown；影响审核决策保存绑定 Revision、新 head、diff hash 和结论。
6. stale 沿依赖图向 dependent 的 dependent 传播，但仍尊重下一条边的跟踪模式和影响规则。

`StaleReason` 至少记录 dependency edge、绑定 ID、比较时的当前 ID、原因和检测时间。每次重新计算替换派生索引，不删除历史 stale/fresh 事件。

### 不能被混淆的状态

- 旧 ShotPlanRevision 引用旧 BeatRevision 仍然是合法、可重放的权威历史；它可以被标记为 `needs_reconciliation`，但其内容本身不“腐烂”。
- GenerationSpec、Provider 请求、未发布 TimelineVersion 等派生或组装产物可以 stale。
- 正在运行的 Attempt 固定在原 Spec 上；输入变更不会注入运行中请求。策略可以取消它，但取消是显式 Attempt 状态迁移。
- 已发布 Release 永远保持原样。发现输入撤销或许可变化时产生 warning/recall decision，不重写历史 Release。
- `stale` 不等于不可用；生产策略决定阻止生成、允许带警告继续或要求重编译。

## 3.8 依赖环与删除

依赖图必须是有向无环图。写边前执行同项目范围的增量环检测；批量导入后执行全图校验。若出现环，整个写边事务失败，不以“稍后修复”接受不确定血缘。

删除规则：

- 未被引用且未进入审计链的草稿可按保留策略物理清理；
- 已被 DependencyEdge、Attempt、Decision、TimelineVersion 或 Release 引用的记录只允许 tombstone/revoke；
- tombstone 保留 ID、类型、哈希、删除 actor、原因和时间；敏感 payload 可按合规策略加密销毁，但血缘占位不可消失；
- 恢复不是取消 tombstone，而是创建新 Revision/Version 并建立 `supersedes` 审计关系。

## 3.9 typed extension

核心对象顶层 `additionalProperties: false`。扩展格式固定为：

```json
{
  "extension_type": "project_color_intent",
  "schema_id": "https://dramatizer.local/extensions/project-color-intent/1.0",
  "schema_version": "1.0",
  "data": { "palette": "cold_office" }
}
```

扩展注册表必须能按 `schema_id + schema_version` 获取验证器。扩展不得：覆盖核心字段语义、改变核心权限、藏入未声明的外部引用、绕过依赖边或把观察数据伪装成权威数据。无法解析的扩展可以只读保存，但不能参与编译或批准。

## 3.10 写入与失败检查

- 创建 Revision：验证父、引用、Schema、扩展、权限和幂等键后一次提交。
- 移动 head：仅比较 CAS token，不重新写 Revision。
- 建立依赖：dependent 所有者写入，目标所有者只提供只读验证。
- 重算 stale：允许重复、乱序；以 `(dependent_id, graph_epoch)` 防止旧计算覆盖新计算。
- diff 服务不可用：状态为 unknown，禁止默认 fresh。
- 图索引不可用：Revision 可提交，但需要生成/发布的命令必须等 impact_pending 清除或由授权策略显式 override。

## 3.11 验收检查

- [ ] 并发编辑不会丢 Revision，CAS 冲突可重现并可三方合并。
- [ ] 任一运行输入都没有浮动 `latest` 引用。
- [ ] 依赖边能说明 exact input 与跟踪新 head 的策略，两者没有混用。
- [ ] 只改 Beat 的无关字段时，受精确 impact path 保护的 Spec 保持 fresh。
- [ ] diff/图服务故障时得到 unknown，而不是错误的 fresh。
- [ ] 已发布成片可在 head 多次前进后按原 Revision 重放。
- [ ] 环形依赖、跨项目引用、错误 entity_type 和无权限引用均在写入时被拒绝。
- [ ] 未注册扩展不能参与编译、规则判断或批准。
