# 12. 架构决策记录

本文件记录 v0.2 会直接约束数据和实现的决策。状态为 `accepted` 的 ADR 在被新 ADR supersede 前有效。

## ADR-001：按权威类型分区，而非把所有数据混为一个事实源

- **状态：** accepted
- **上下文：** 叙事事实、调用记录、检测结果和审核行为都是真实记录，但权威范围不同。
- **决定：** 使用 Narrative、Directing、Derived Execution、Observation、Decision 五个分区；每个对象声明 authority class 和写入者。
- **拒绝：** 把模型输出直接回写 Canonical 表；这会丢失计划与实际差异。
- **后果：** 查询需要跨对象聚合，但写入权限和审计含义清晰。

## ADR-002：稳定 Logical ID 与不可变 Revision ID 分离

- **状态：** accepted
- **决定：** 可编辑实体使用 logical ID、immutable revision ID 和显式 head pointer。执行和 Release 只引用 revision ID。
- **拒绝：** 使用 `id + revision_number` 作为唯一外部引用；跨分支、导入和并发创建时容易冲突。
- **后果：** 需要 Revision 索引、父 Revision、分支和乐观锁规则。

## ADR-003：StoryEvent 与 ShotPlan 分离

- **状态：** accepted
- **决定：** StoryEventRevision 表示语义事实；DirectorPlanRevision/ShotPlanRevision 表示导演表达；通过 coverage relation 建立多对多关系。
- **拒绝：** 继续让 CanonicalShot 同时充当事实、导演方案、候选和审批对象。
- **后果：** 可以支持一事实多方案、多镜头覆盖同一事件和平台改编。

## ADR-004：连续性使用显式快照、转换和边

- **状态：** accepted
- **决定：** 使用 typed StateSnapshot、StateTransition、DetectedObservation、ContinuityApproval 和 ContinuityEdge；不依靠数组顺序推断“上一镜头”。
- **拒绝：** 继续使用无主体的任意 `planned_state` object。
- **后果：** Schema 更明确；非线性叙事和交叉剪辑可以选择独立 continuity sequence。

## ADR-005：按实体拆分生命周期

- **状态：** accepted
- **决定：** Revision、WorkflowRun、NodeRun、Task、Attempt、Asset QC、Review、Timeline 和 Release 使用独立状态机。
- **拒绝：** 将 `draft/generating/qc_failed/approved/released` 放进单一 approval status。
- **后果：** UI 需要聚合多个状态，但不会出现语义非法转换。

## ADR-006：工作流采用至少一次投递与业务幂等

- **状态：** accepted
- **决定：** Queue、Worker 和 Callback 都按 at-least-once 设计；使用 Inbox/Outbox、唯一键和幂等副作用收敛。
- **拒绝：** 声称 exactly-once；外部 Provider 和对象存储无法提供端到端保证。
- **后果：** 每个副作用必须定义幂等作用域和重复事件处理。

## ADR-007：资产使用 staged → finalized 提交协议

- **状态：** accepted
- **决定：** 对象先暂存并验证 hash/媒体元数据，再用数据库事务创建 finalized AssetVersion 和血缘；失败对象进入 quarantine/orphan 回收。
- **拒绝：** Provider 回调到达后立即写“可用资产”。
- **后果：** 需要 finalize worker、补偿任务和孤儿清理策略。

## ADR-008：路由解析结果固定到 Attempt

- **状态：** accepted
- **决定：** CapabilityRequirement 与 RoutePolicy 解析为 ResolvedExecutionPlan；每个 Attempt 固定 Provider、模型版本、Adapter 和配置快照。Fallback 创建新 Attempt。
- **拒绝：** 在运行中静默切换 Provider 或引用动态 `latest` 模型。
- **后果：** 可复现性和归因提高；路由变化不会污染在途任务。

## ADR-009：质量证据、自动建议和人工裁决分离

- **状态：** accepted
- **决定：** Analyzer 产生 QualityEvidence，规则/模型聚合成 AutomatedQualityDecision，ReviewDecision 记录最终批准、拒绝、修复、重生成或 waiver。
- **拒绝：** 把自动 `pass` 直接映射为 `approved`。
- **后果：** 需要额外对象，但保留了完整责任链。

## ADR-010：MVP 控制平面采用模块化单体

- **状态：** accepted
- **决定：** Phoenix Control Plane 内保留清晰模块边界；Media、CV、GPU Worker 和外部 Provider 独立运行。
- **拒绝：** M0 即拆分大量微服务；当前规模不足以抵消运维和一致性成本。
- **后果：** 必须禁止跨模块直接操作私有表，避免形成无边界单体。

## ADR-011：Agent 写入使用命令与变更提案

- **状态：** accepted
- **决定：** MCP 写工具提交 typed command/change proposal，并携带 actor、project、base revision、idempotency key 和 reason；服务端执行权限、验证、乐观锁和审计。
- **拒绝：** 暴露绕过领域服务的 `update_*` 数据库式工具。
- **后果：** Agent 多一步批准或冲突处理，但不会静默污染权威数据。

## ADR-012：Rights Gate 与 Budget Gate 是真实提交前置条件

- **状态：** accepted
- **决定：** 所有真实生成在 Provider submit 前完成授权覆盖和预算预留；许可未知、禁止派生或预算不足时停止。
- **拒绝：** 只记录成本和 license metadata，等导出时才发现不可用。
- **后果：** 需要早期成本估算、许可规则和可审计 waiver。

## ADR-013：正式 Spec 编译确定；非确定性只存在于提案与生成

- **状态：** accepted
- **决定：** `ShotPlanRevision → GenerationSpecRevision` 是不包含 LLM 的确定性编译；固定输入 Revision 闭包、编译器与策略版本必须得到相同规范化输出/hash。LLM 可产生待审 Director proposal，Provider 可产生非确定候选，两者均不属于正式 Spec 编译。
- **拒绝：** 把 LLM 放进正式编译器后仍声称相同输入可复现；也拒绝因 Provider 输出非确定而放弃请求/响应血缘。
- **后果：** Spec 可缓存、比较和重放；非确定候选仍固定请求快照、模型/参数/seed 和输出 hash，但不承诺位级复现。

## ADR-014：渲染输入与最终发布使用两份不可变清单

- **状态：** accepted
- **决定：** 渲染前 `RenderInputManifest` 只有在 render-use RightsGate 为 `allowed`、输入 availability 全部为 `available` 时才能创建，并固定 TimelineVersion、Clip、源 AssetVersion、字幕、混音参数、渲染配方、授权/批准快照与 availability snapshot hash；渲染执行前再次核对。导出 AssetVersion finalize 且整集 QC 完成、最终 ReleaseGate 为 `ready/waived` 且未过期后，`ReleaseManifest` 再固定 RenderInputManifest、最终导出资产、整集质量证据、最终 RightsGate ID/status/hash/valid-until、批准/waiver 集、availability snapshot hash 与发布元数据。两者都只引用不可变 ID/hash。
- **拒绝：** 在导出资产尚不存在时伪造“完整 ReleaseManifest”，或让 Release 引用 logical head/动态策略。
- **后果：** 昂贵渲染有稳定输入，最终发布又能证明实际导出物；重新渲染或重新发布必须创建新清单/ReleaseCandidate，不能改写旧记录。

## 保留问题与默认策略

以下问题不阻塞领域合同，实施 Spike 后可用新 ADR 调整：

1. **Provider 商务和地域能力：** 默认全部从运行时能力快照读取，不写死在领域 Schema。
2. **完整 QC 的候选数量：** 默认所有候选跑技术 QC；其余层按策略 shortlist，但最终采用候选必须完成所有 required 检查。
3. **原生台词偏差：** 默认不允许静默替换 DialogueRevision；如采纳更优台词，创建 CanonicalChangeProposal 和新 DialogueRevision。
4. **stale 发布策略：** 默认 Release Gate 阻止 required dependency stale；有权限的 waiver 必须限定范围和版本。
5. **跨项目资产复用：** 默认不共享，仅在许可、项目策略和访问控制均允许时创建显式授权引用。
6. **模型/CV 阈值升级：** 旧报告永久保留；是否重跑由策略创建新 QualityReport，不覆盖旧报告。
