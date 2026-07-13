# 5. 连续性模型 v0.2

## 5.1 目标与边界

连续性模型负责在镜头间传递角色、服装、场景、道具、空间、伤病、时间和环境状态，同时保证生成检测不会自动污染事实源。

正式链路为：

```text
上一镜头 approved_end ContinuitySnapshot
  └── ContinuityEdge
        → 当前镜头 planned_start ContinuitySnapshot
        → StateTransition(actions)
        → planned_end ContinuitySnapshot
        → Candidate AssetVersion
        → DetectedObservation[]
        → ContinuityApproval
        → 新的 approved_end ContinuitySnapshot
```

planned snapshot/transition 属于 Directing Authority；检测属于 Observation；批准属于 Decision。批准生成的 `approved_end` 是后续生产可依赖的决策授权状态，但不会自动成为 Narrative Authority。若偏差改变剧情事实，必须另外创建 Beat/StoryEvent Revision。

## 5.2 StateFact 与三值存在语义

每条状态事实由 exact subject、属性路径和 `StateValue` 组成：

```json
{
  "subject_ref": {
    "entity_type": "prop_version",
    "logical_id": "prop_contract",
    "revision_id": "rev_..."
  },
  "attribute_path": "/possession/holder_hand",
  "state": {
    "presence": "known",
    "value": "char_lin.right_hand"
  }
}
```

`presence` 的语义严格区分：

| 值 | 含义 | 是否允许 `value` |
|---|---|---|
| `known` | 已明确知道该属性的值 | 必须有 |
| `unknown` | 该属性在范围内，但目前无法确定 | 禁止有；可写原因 |
| `not_present` | 已明确确认主体/属性所表示对象不存在或未出现 | 禁止有；可写原因 |

字段完全省略表示“不在该快照或观察的声明范围内”，不等价于 unknown。尤其在 DetectedObservation 中：

- `observation_scope` 包含路径且结果是 `unknown`：检测器尝试过但无法判定；
- scope 包含路径且结果是 `not_present`：检测器明确判断未出现；
- scope 不包含路径：检测器没有承诺检查，不能拿来作连续性结论。

`unknown` 不是通配符，也不自动兼容任何值；它在严格连续性门中产生 `unresolved`。`not_present` 与一个 known present 值冲突。

## 5.3 时间范围

镜头内时间使用整数毫秒和半开区间 `[start_ms, end_ms)`：

- `start_ms >= 0`；
- `end_ms > start_ms`；
- 对观察，`end_ms` 不得超过被分析 Candidate AssetVersion 的探测时长；
- 对计划动作，`end_ms` 不得超过 ShotPlan 的 `maximum_ms`；
- 时间基准始终是该镜头/资产的本地零点，不是 Episode 全局时间线；
- TimelineClip 负责把素材本地时间映射到成片时间。

JSON Schema 能校验类型和下界，但 `end_ms > start_ms`、时长上界和跨对象对齐由确定性领域验证器检查。

Snapshot 的 `boundary.offset_ms` 是边界位置：计划开始通常为 0，计划结束通常为 preferred duration；批准结束可以使用实际候选时长。它不是一个持续区间。

## 5.4 ContinuitySnapshot

Snapshot 是不可变的边界状态集合，类型只有：

- `continuity_seed`：Episode/Scene/连续性轨道的初始状态，不绑定 ShotPlan；
- `planned_start`：导演计划的镜头起始状态；
- `planned_end`：应用计划转换后的预期结束状态；
- `approved_end`：ContinuityApproval 输出、允许作为后续输入的状态。

除 `continuity_seed` 外，每个 Snapshot 都精确绑定一个 ShotPlanRevision，并包含 basis、facts、actor 和时间。seed 不绑定 ShotPlan，它通过 `narrative_revision` 或 `authorized_import` basis 绑定初始来源。Snapshot 没有可变 head；ShotPlan 改动时创建新的 ShotPlanRevision 及新快照。

Schema 强制以下合法组合，不能把 kind、边界和来源自由拼装：

| snapshot_kind | ShotPlan 引用 | boundary | basis_type / source |
|---|---|---|---|
| `continuity_seed` | 禁止 | `start`, `offset_ms=0` | `narrative_revision` + VersionedRef，或 `authorized_import` + ImmutableRef |
| `planned_start` | 必须 | `start`, `offset_ms=0` | `director_plan` + VersionedRef |
| `planned_end` | 必须 | `end`, `offset_ms>=1` | `director_plan` + VersionedRef |
| `approved_end` | 必须 | `end`, `offset_ms>=1` | `continuity_approval` + ImmutableRef |

Snapshot 完整性按项目/镜头类型策略定义。例如主角特写可能要求身份、服装、双手持物、伤病、位置和情绪；未要求的属性可以不出现。需要跟踪但暂不确定的属性必须写 unknown，不能省略以绕过检查。

同一 Snapshot 内 `(subject_ref, attribute_path)` 必须唯一。若一个属性随镜头内时间变化，应由 StateTransition 表达，不在边界 Snapshot 中写多个冲突值。

## 5.5 StateTransition

一个 ShotPlanRevision 恰好绑定一条计划 StateTransition：

```text
from_snapshot_id == planned_start_snapshot_id
to_snapshot_id   == planned_end_snapshot_id
```

每个 `TransitionAction` 必须：

- 关联一个绑定 Beat Revision 中存在的 `story_event_id`；
- 指定 exact subject 与属性路径；
- 声明 `expected_before` 和 `planned_after`；
- 指定操作和镜头内时间范围；
- 不把相机动作误写成故事世界状态变化。

确定性验证器按时间顺序应用 action：

1. 起点取 planned_start facts；
2. `expected_before` 与当前状态不兼容时失败；
3. 应用 action 后更新工作状态；
4. 结束工作状态必须与 planned_end facts 一致；
5. 未被 action 修改但在两端都声明的属性默认必须相同；显式允许漂移的属性由版本化 continuity policy 决定。

动作区间可以重叠，但对同一 subject/path 的冲突写入必须有确定顺序，否则计划无效。

## 5.6 DetectedObservation

Observation 是针对一个 exact Candidate AssetVersion 的检测记录。它必须同时引用 ShotPlanRevision、GenerationAttempt、Candidate AssetVersion、检测器实现/版本/配置哈希和证据资产。

每条 ObservedFact 包含：

- subject 和属性路径；
- observed StateValue；
- `0..1` 置信度及 calibration ID；
- 时间范围；
- 一到多个 evidence AssetVersion，例如抽帧、轨迹、波形或结构化报告。

置信度只属于 Observation，不属于权威 Snapshot。不同检测器的冲突结果全部保留，不能用“最后写入者”覆盖。聚合器可以产生新的综合 Observation，但必须引用源证据，且仍不是 Decision。

检测器配置或校准变化时旧 Observation 保留；重新分析创建新 Observation。人工标注也走相同 Observation 合同，`detector_type=human_annotation`，以便事实来源清晰。

## 5.7 ContinuityApproval

Approval 是不可变决策，包含：

- exact ShotPlanRevision；
- 输入 planned snapshot IDs 和 Observation IDs；
- decision：`accept_planned`、`accept_observation`、`manual_override` 或 `reject`；
- 决策 actor、时间、authority、原因；
- 非 reject 时生成的 `approved_snapshot_id`；
- 自动/批量决策使用的 exact policy Revision。

决策分支还必须满足：

| decision | Observation 输入 | authority | approved_snapshot_id |
|---|---|---|---|
| `accept_planned` | 可为空 | 任一获授权类型 | 必须产生 |
| `accept_observation` | 至少 1 个 | 任一获授权类型 | 必须产生 |
| `manual_override` | 可为空 | 只能是 `human` | 必须产生 |
| `reject` | 可为空 | 任一获授权类型 | 禁止出现 |

`manual_override` 的差异以 planned input 与输出 approved Snapshot 的确定性 diff 表达，并由非空 reason 解释；它不能绕过 Narrative Revision 要求。

权限规则：

| authority | 可用主体 | 约束 |
|---|---|---|
| `human` | 有连续性审核权限的用户 | UI 必须展示计划、观察、置信度和证据 |
| `deterministic_policy` | 无模型随机性的规则服务 | 必须保存 Policy Revision；只处理策略明确允许的低风险字段 |
| `audited_batch_policy` | 预先审批的批量规则 | 必须可追溯审批范围、操作者和批次 |

LLM、Gemini 或 CV 不能作为 approval authority；它们只能产生 Observation 或建议。

接受观察不是把检测 JSON 复制成事实。批准者必须构造一个满足完整性策略的新 `approved_end` Snapshot：逐项选择 planned、observed 或 manual override 值，并可显式保留 unknown。Approval 和输出 Snapshot 预分配 ID，并在同一事务提交，避免一方存在、一方缺失。

`reject` 不产生 approved snapshot，后续 ContinuityEdge 不得引用该 Approval。

## 5.8 ContinuityEdge 与显式顺序

组合树中的 Shot index 和 TimelineClip 顺序都不能替代连续性顺序。每条 Edge 明确连接：

```text
predecessor.snapshot_id（通常是 approved_end）
→ successor.shot_plan_revision_ref + planned_start_snapshot_id
```

并保存：

- `track_id`：连续性轨道，例如主叙事、平行动作 A、回忆；
- `ordinal`：该轨道边的顺序号；
- `relation`：continuous、cutaway、time/location jump、parallel 或 declared discontinuity；
- exact comparison policy Revision。

Episode 初始状态使用 `continuity_seed` Snapshot，可作为没有 predecessor ShotPlan 的起点，因此 Schema 允许 predecessor 仅含 snapshot ID。其 basis 必须是 Narrative Revision 或已授权导入。

不变量：

1. `(project_id, track_id, ordinal)` 唯一；`track_id` 在一个 Episode 连续性语境内稳定，不把无关的 Episode Revision 写进唯一键；
2. 同一 track 的 edge 构成有向无环序列；分支必须显式建立新 track 或声明 parallel relation；
3. successor 必须引用 `planned_start`，正常 predecessor 必须引用 `approved_end`；
4. `continuous` Edge 对 policy 要求的所有属性做严格比较；
5. jump/discontinuity 不代表跳过校验，而是应用另一套明确 Policy；
6. 改 ShotPlanRevision 后旧 Edge 保留为历史，新 Revision 使用新 Edge；禁止原地换 endpoint。

ContinuityEdge 通过 endpoint exact refs、comparison policy ref 与依赖图参与 stale 判定。Episode 产生新 Revision 时，只有 diff 命中该 track 的成员、时序、上下文或 Policy 依赖才使 Edge stale；无关场次/元数据修改允许新 Episode Revision 复用原 Edge ID。若 track 自身的顺序或分支结构变化，创建新的 track revision/Edge 集，旧集合仍供历史 Release 重放。该规则由依赖图与领域 validator 执行，不能仅凭 Episode revision ID 全量重建。

## 5.9 连续性比较结果

比较器读取 predecessor approved facts、successor planned facts 和 Policy，输出派生报告：

- `compatible`：所有必检字段满足规则；
- `conflict`：至少一个确定值冲突；
- `unresolved`：必检字段 unknown、缺失、Observation 冲突或证据不足；
- `stale`：任一 endpoint、Policy 或依赖已被撤销/替换且跟踪规则要求重算。

比较报告是 Observation/Derived Evidence，不是 ContinuityApproval。系统可以让确定性 Policy 对低风险 compatible 报告批量批准，但必须另建 Decision。

典型比较语义：

```text
known("right_hand") vs known("right_hand") → compatible
known("right_hand") vs known("left_hand")  → conflict
known("right_hand") vs unknown             → unresolved
not_present         vs known(value)         → conflict
attribute omitted while policy requires it → unresolved
```

## 5.10 基数与写入所有权

| 关系 | 基数/所有者 |
|---|---|
| ShotPlanRevision → planned_start/planned_end | 各 1，由 Director Service 原子创建 |
| ShotPlanRevision → StateTransition | 1，由 Director Service 创建 |
| Candidate AssetVersion → DetectedObservation | 0..*，由 QC/标注服务追加 |
| ShotPlanRevision → ContinuityApproval | 0..*，由 Review Service 追加 |
| accepted Approval → approved_end Snapshot | 恰好 1，由 Review Service 同事务创建 |
| approved_end Snapshot → outgoing Edge | 0..*，由 Continuity Service 创建 |
| planned_start Snapshot → incoming Edge | 0..*；主 track 通常 1，分支需策略允许 |

Director Service 不能写 Observation/Approval；QC 不能写 planned/approved Snapshot；Review Service 不能改 Beat/ShotPlan；Continuity Service 只建 Edge 和比较报告，不重写 endpoint。

## 5.11 失败与并发边界

- ShotPlanRevision、两个 planned Snapshot 和 StateTransition 作为一个创作命令提交；任一校验失败则全部不提交。
- 多个检测器可并发追加 Observation，不互斥；ID 和幂等键防止相同分析任务重复写。
- 两位审核者可从同一输入提交不同 Approval。Review Service 通过“active continuity decision” CAS 选择生效者；两项历史决策都保留，冲突必须显式解决。
- 创建 Edge 时锁定 successor 的 active plan binding，并再次验证 predecessor active Approval；任一变化则返回 `continuity_endpoint_changed`。
- 检测超时产生失败记录或 scope 内 unknown，不得伪造 not_present。
- Candidate 媒体无法解码时不运行语义检测；技术 Observation 记录 hard failure，Approval Policy 决定 block/reject。
- Edge 比较服务不可用时结果是 unresolved/unknown，不能默认 compatible。
- 接受偏差后若后续镜头已编译，其相关 GenerationSpec 根据 DependencyEdge 标 stale；是否重生成由工作流策略决定。

## 5.12 验收检查

- [ ] `known` 无 value、`unknown/not_present` 带 value 均被 Schema 拒绝。
- [ ] scope 外未观察、scope 内 unknown 和明确 not_present 在 UI/API 中可区分。
- [ ] ObservedFact 有 detector、校准置信度、时间范围和 evidence 引用。
- [ ] planned start + actions 可确定性得到 planned end；冲突动作被拒绝。
- [ ] LLM/CV/Gemini 不能创建 Approval 或 approved Snapshot。
- [ ] accept observation 会创建独立批准快照，而不是修改 planned/detected 数据。
- [ ] 相邻关系由 Edge 明确表达，不依赖数组位置、文件名或 Timeline 顺序。
- [ ] 并发审批不丢历史，只有 CAS 选中的 decision 对新 Edge 生效。
- [ ] 上游批准状态变化能精确标记下游计划、Spec 和 Timeline warning 的影响。
