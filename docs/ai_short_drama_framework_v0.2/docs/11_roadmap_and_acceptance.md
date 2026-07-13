# 11. 实施路线图与可测试验收

路线图按风险退休顺序推进：先冻结合同，再用 Fake 验证状态与失败语义；先单 Shot 的真实闭环，再扩展整集。幂等、最低安全、权利、成本和技术 QC 是地基，不是稳定化阶段的补丁。

## 11.1 全阶段共同完成定义

每阶段只有同时满足以下条件才可退出：

- 交付物有版本化 Schema/API、迁移、权限守卫、审计事件和可观测性；
- 新行为有自动化测试，失败/重试/并发路径不只测 happy path；
- 没有 Stub 伪造外部成功；Fake 的输出、成本、延迟和故障均可配置；
- lint、类型检查、单元/契约/集成测试通过，迁移可在空库和上一基线运行；
- 关键状态可从 event/audit/asset lineage 重建，错误可定位到 project/trace/workflow/node/attempt；
- 阶段验收使用固定 fixture 和机器可判定断言，不以演示视频代替证据。

## P0：合同基线

### 目标与交付

- 冻结 logical ID、revision ID、head pointer、不可变 asset 和 exact ref 语义；
- 定义四层表示、连续性快照/转移、分实体状态机；
- 定义 WorkflowRun/NodeRun/ProviderAttempt、ProviderRequestSnapshot、QualityEvidence/Decision、RightsGate、ReleaseGate 与 PublishAttempt；
- JSON Schema 2020-12、错误码、幂等键、outbox/inbox 和 audit envelope；
- 最小 threat model、权限矩阵、retention class 和成本账本合同；
- Architecture Decision Records：PostgreSQL/Object Storage 边界、消息投递语义、Provider adapter 边界。

### 可测试验收

- 所有示例均通过 Schema 验证；故意添加未知顶层字段必须失败，`extensions` 可通过；
- 属性测试证明 revision 不可修改、head CAS 冲突不丢更新、非法状态转换被拒绝；
- 契约测试证明同一 idempotency key 不创建第二个业务结果；
- threat-model 测试用例覆盖跨项目引用、无权限 approve/waive/release、rights 未知和预算不足；
- 文档中的每个状态、对象名和枚举在 Schema/API 中有唯一含义。

## P1：Fake 端到端垂直切片

### 目标与交付

- 项目 → Episode → Scene/Beat → ShotPlan → GenerationSpec 的最小编译链；
- Fake Provider、ProviderAttempt、独立 ProviderRequestSnapshot、UploadIntent/finalized AssetVersion、候选 QC、人工批准；
- 单轨 placeholder Timeline、整集 Release QC、ReleaseGate 和本地导出 placeholder；
- 从第一天启用 rights preflight、成本预留/结算、技术 QC、幂等、回调 inbox/outbox、审计和 trace。

### 可测试验收

- 不调用真实模型可跑通一集 3 Shot，并能从任意 NodeRun 失败后恢复；
- 注入重复/乱序回调、进程崩溃和对象 finalize 半失败，最终只产生一个采用结果且无悬空可见资产；
- 损坏媒体触发技术硬失败并短路依赖层；自动 pass 后仍不能无 ReviewDecision 进入受控时间线；
- 未授权输入、过期肖像/声音许可、超预算均在 Provider 调用前阻断；
- 所有最终引用可追溯至 Canonical/Director/Generation revision、Attempt、Provider request、asset hash 和审核人。

## P2：叙事编译闭环

### 目标与交付

- SeriesBible、Character/Location/Prop、Episode/Scene/Beat 的 revision 编辑与引用验证；
- NarrativeFactRevision → DirectorPlanRevision 的受审创作/结构化导演方案，以及 ShotPlanRevision → GenerationSpecRevision 的确定性编译；
- 连续性 start/planned/detected/approved state 与 edge；
- stale 传播、影响分析、ChangeProposal 审批和增量重编译；
- 人工可编辑的 Shot 列表和叙事/导演方案对比。

### 可测试验收

- 固定 ShotPlanRevision 输入重复编译得到相同规范化 GenerationSpec 输出/hash；导演 Agent 的非确定性提案须经审核成为新的 DirectorPlanRevision，编译器或策略升级产生新 revision 而非覆盖；
- 删除/改名被引用角色、场景、道具时编译失败并返回精确路径；
- 修改角色服装 revision 只标记真实依赖的 Shot/资产 stale；旧发布物保持可重现；
- detected observation 不能直接成为 approved snapshot；ContinuityApproval（`accept_observation`/`manual_override`）与 CanonicalChangeProposal 路径均有授权与审计测试；
- 允许同一 NarrativeFactRevision 并存两个 DirectorPlanRevision 且资产不串线。

## P3：视觉预演闭环

### 目标与交付

- 首个真实图像 Provider（角色、场景、道具、关键帧）及 Fake/record-replay adapter；
- 候选对比、批准、锁定和血缘；
- 最小 FFmpeg 拼接、临时 TTS/静音策略、句级字幕和竖屏 Animatic；
- 图像/字体/临时声音 rights gate、媒体技术 QC 和成本计量。

### 可测试验收

- 无视频生成即可导出 60–120 秒、10–30 Shot 的 9:16 Animatic，包含临时音频或显式静音与字幕；
- 改变某 Shot 时只重建受影响 clip 和导出，缓存命中不重复计费；
- Provider 超时、限流、内容拒绝和 schema 漂移分别映射为稳定错误/重试策略；
- 输出分辨率、时长、画幅、音轨和字幕安全区由自动技术 QC 验证；
- 所有输入和输出有 hash、rights snapshot、费用、采用/弃用状态。

## P4：单 Shot 真实生成闭环

### 目标与交付

- 首个真实视频 Provider 与至少一条可用声音策略（原生音频或外配音）；
- 单 Shot GenerationAttempt 的提交、轮询/回调、取消、重试、预算和恢复；
- UploadIntent staged/finalize、不可变 AssetVersion 与独立 quarantined availability projection，以及恶意媒体隔离；
- L1 技术 QC；L2 Gemini 与 L3 基础 CV 并行；异常触发定向 CV；L4 叙事建议；
- A/B 候选、人工 ReviewDecision、repair/regenerate 和 continuity 处置。

### 可测试验收

- 使用固定 5–10 秒 Shot fixture 生成至少两个候选，批准其中一个并构建单 clip timeline；
- 损坏文件、缺失必要音轨、角色偏离、连续性偏差和 Provider 迟到结果均进入预期状态且可定位；
- 自动 `pass` 不会自动 `approve`；无权限或无理由/范围/到期时间的 waiver 被拒绝；
- Gemini 与基础 CV 的执行图可证明并行，定向 CV 仅在风险/证据触发时运行；
- 重试不覆盖 Attempt，单 Shot 可独立重生成，旧候选和决定仍可审计；
- 真实 Provider 的 secret 不出现在日志、prompt snapshot 或错误响应。

## P5：整集生产与发布闭环

### 目标与交付

- 批量 Shot 调度、背压、Provider 限额和项目预算；
- 原生音频与外配音双路径、音乐/SFX、响度处理、多轨时间线、字幕；
- 冻结 TimelineVersion 与 RenderInputManifest、确定性 FFmpeg export recipe、代理与成片；
- 导出 finalize 后执行独立整集 Release QC、rights re-evaluation、ReleaseGate，并创建最终 ReleaseManifest；
- 追加式 PublishAttempt、平台幂等键、ACK 丢失后的查询/对账与禁止盲目重发；
- 失败节点恢复、局部重生成、过期决定/stale 传播和发布审计。

### 可测试验收

- 生产并导出一集 60–120 秒、10–30 Shot 的 9:16 成片，成片 hash 与 manifest 一致；
- 进程在生成、下载、finalize、QC、时间线和导出各阶段被杀后均可恢复，无重复采用/计费记录；
- 替换一个已批准 Shot 后，旧 ReleaseGate 自动失效，只重跑受影响候选检查与完整 Release QC；
- 最终文件通过解码、平台规格、响度、字幕安全区、clip 边界和 A/V 同步检查；
- 每个时间线 clip 有有效 approval/waiver，每项素材权利覆盖目标渠道/地域/期限；
- 发布命令重复执行只产生一个平台发布结果；ACK 丢失进入 `unknown_remote_state` 并先查询/对账，撤回后不能原地改写历史 Release。

## P6：稳定化与 MVP 退出

### 目标与交付

- Provider 健康度、熔断、限流、公平调度和降级；
- 基准集、质量阈值校准、模型/策略迁移和 record-replay 回归；
- 成本/采用率/重生成率/人工推翻率/waiver 指标与告警；
- retention/deletion/legal hold、备份恢复、DR、密钥轮换和权限复核；
- 性能、容量、安全、混沌和故障演练；运维手册与 SLO。

### MVP 退出标准

- 连续运行基准集并产出至少一集成片；机器验收固定核对 manifest/hash、时长/画幅/编码、响度、字幕安全区、A/V 同步、权利/availability/waiver 有效性，人工只对表演与叙事主观项作结构化复核；无 P0/P1 已知缺陷；
- 同一输入/版本/策略可复现编译和决策，非确定性 Provider 输出仍有完整 request/response/seed 血缘；
- 端到端成功率、P95 阶段耗时、单位采用 Shot 成本和人工介入率达到项目设定阈值；
- 重复/乱序事件、Provider 宕机、对象存储半失败、数据库切换和 worker 崩溃演练通过；
- 越权、prompt injection、恶意媒体、跨项目 hash 探测、rights 撤销和 waiver 到期测试通过；
- 单 Shot 可独立重生成，变更影响范围正确，已发布版本可追溯且不可改写；
- 值班人员可仅凭 runbook 定位并恢复一次预置故障。

## 11.2 P6 之后的增强项

- 第二视频/图像 Provider 与基于能力、成本和健康度的路由；
- forced alignment、专用口型修复、表演驱动和高级音源分离；
- 专用纯音效、音乐 stem、多语言和自动配音版本；
- 反馈驱动阈值建议，但策略发布仍需评审、版本化和回归；
- 模型能力月度复核、影子流量和可回滚迁移。

这些增强不得绕过既有 revision、rights、quality、approval、cost 和 ReleaseGate 合同。

## 11.3 依赖与禁止倒置

1. 合同与状态守卫先于 UI；
2. Fake 故障语义先于真实 Provider；
3. rights/security/cost preflight 先于任何外发调用；
4. staged/finalized、hash 和幂等先于资产复用；
5. 最小技术 QC 先于批准真实资产；
6. 单 Shot 真实闭环先于整集并发；
7. 候选 QC 与整集 Release QC 分开；
8. 人工可接管、可解释、可回滚先于自动化扩张。
