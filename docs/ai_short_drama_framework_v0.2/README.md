# AI 短剧生产框架设计 v0.2

**状态：** 实施前领域与运行时合同  
**基准日期：** 2026-07-13  
**上游基线：** `../ai_short_drama_framework_v0.1/`

v0.2 不替换 v0.1 的产品愿景，而是把其中尚未收口的领域边界、版本规则、连续性、状态机、工作流、质量证据、Provider 路由、资产提交和发布门细化为可实施合同。

## 规范用语

- **必须 / 不得**：实现和数据必须满足；违反即为合同错误。
- **应该 / 不应该**：默认必须遵守，偏离需要 ADR 或项目级显式策略。
- **可以**：可选能力，不得改变核心不变量。
- 文档与 Schema 冲突时，先停止写入路径并修正文档与 Schema；不得选择性解释后继续生产。

## MVP 产品边界

- 9:16 中文连续短剧；
- 单集目标时长 60–120 秒；
- 每集约 10–30 个 ShotPlanRevision；
- 支持真人风格和其他视觉风格，但首个基准集以人物连续性要求较高的真人风格为准；
- 从结构化叙事、导演方案、候选生成、质量证据、人工审核、非破坏性时间线到导出闭环；
- 人工对权威数据变更、资产批准、偏差接受和 Release 负最终责任；
- MVP 允许 Manual/Unavailable 能力，但不得伪造成功或绕过发布门。

## 全局不变量

1. Prompt、Provider 请求和模型输出都不是权威叙事事实。
2. 所有生产、审核和发布引用不可变 revision ID 或 asset version ID，不引用浮动 `latest`。
3. 自动检测只生成证据；自动质量结论不等于人工批准。
4. 接受生成偏差必须产生可审计决定；改变权威事实必须创建新 Revision。
5. 工作流采用至少一次投递与业务幂等，不承诺 exactly-once。
6. Provider 特有字段只存在于 Adapter 配置、能力快照和请求/响应快照。
7. 数据库记录和对象存储对象完成 finalize 前，不得创建可批准的 AssetVersion。
8. Rights Gate、Budget Gate、能力解析和输入新鲜度检查必须发生在外部生成提交前。
9. 渲染前固定 RenderInputManifest；导出 finalize 与整集 QC 后才创建 ReleaseManifest，二者均引用精确版本闭包，后续 head 变化不污染历史 Release。
10. Agent/MCP 写操作必须经过命令、验证、权限、乐观锁和审计链。

## 文档目录

| 文件 | 规范内容 |
|---|---|
| `docs/01_scope_and_principles.md` | 产品边界、设计原则、权威分区、模块边界 |
| `docs/02_glossary_and_domain_model.md` | 术语、实体、基数和聚合边界 |
| `docs/03_identity_revision_and_dependencies.md` | Logical ID、Revision、依赖和 stale |
| `docs/04_representation_and_compilation.md` | 四层表示、编译、验证和可重放性 |
| `docs/05_continuity_model.md` | 连续性快照、转换、检测与批准 |
| `docs/06_state_machines.md` | 分实体状态机、守卫和写权限 |
| `docs/07_workflow_runtime.md` | Workflow/Node/Task/Attempt 和恢复语义 |
| `docs/08_provider_routing_cost_and_observability.md` | 能力、路由、预算、配额和遥测 |
| `docs/09_quality_review_and_release.md` | 质量证据、自动建议、人工裁决和发布门 |
| `docs/10_storage_security_and_rights.md` | 资产提交、存储一致性、安全和授权 |
| `docs/11_roadmap_and_acceptance.md` | 垂直切片路线图与可测试验收 |
| `docs/12_architecture_decisions.md` | v0.2 正式 ADR 与保留问题 |

## 机器合同与样例

| 合同 | Schema | 正例 |
|---|---|---|
| 公共 ID、引用、时间、类型化扩展 | [`common.schema.json`](schemas/common.schema.json) | 被其他合同复用 |
| ShotPlanRevision | [`shot-plan-revision.schema.json`](schemas/shot-plan-revision.schema.json) | [`shot-plan-example.json`](examples/shot-plan-example.json) |
| 连续性快照、转换、观察、批准、边 | [`continuity.schema.json`](schemas/continuity.schema.json) | [`continuity-example.json`](examples/continuity-example.json) |
| 工作流、生成、资产提交与发布尝试 | [`workflow-runtime.schema.json`](schemas/workflow-runtime.schema.json) | [`workflow-run-example.json`](examples/workflow-run-example.json) |
| Provider 请求快照 | [`provider-request-snapshot.schema.json`](schemas/provider-request-snapshot.schema.json) | [`provider-request-snapshot-example.json`](examples/provider-request-snapshot-example.json) |
| Provider 路由、预算与成本 | [`provider-routing.schema.json`](schemas/provider-routing.schema.json) | [`provider-routing-example.json`](examples/provider-routing-example.json) |
| RightsGate 与人工复核 | [`rights-gate.schema.json`](schemas/rights-gate.schema.json) | [`rights-gate-example.json`](examples/rights-gate-example.json) |
| 质量、审核、waiver 与 ReleaseGate | [`quality-report.schema.json`](schemas/quality-report.schema.json) | [`quality-report-example.json`](examples/quality-report-example.json) |

## 实施阅读顺序

1. 先读 01–05，确认领域与 Revision 合同；
2. 再读 06–08，确认运行时、路由与成本合同；
3. 再读 09–10，确认批准、发布、安全和授权边界；
4. 按 11 的阶段门实施；
5. 修改核心不变量前先更新 12 中的 ADR。

`schemas/` 是可交换数据的机器合同；数据库表可以规范化拆分，但不得改变字段语义。`examples/` 是合同样例而非生产默认值。`diagrams/` 只帮助理解，发生冲突时以正文和 Schema 为准。

在 PowerShell 7 中运行 [`tools/validate_contracts.ps1`](tools/validate_contracts.ps1)，可验证 Draft 2020-12 Schema、全部样例、关键非法负例和本地文档链接。该脚本不得替代领域级引用闭包、状态迁移和跨记录不变量测试。

跨模型审计结论、已修复问题和实施期残余风险见 [`audit/cross-model-audit.md`](audit/cross-model-audit.md)。当前设计包的 SHA-256 冻结清单见 [`manifest.sha256`](manifest.sha256)；清单不包含自身。
