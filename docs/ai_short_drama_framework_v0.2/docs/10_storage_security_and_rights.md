# 10. 存储、事务边界、安全与权利合同

本章定义二进制对象、数据库元数据、外部回调、Agent/MCP 写入和素材权利的共同安全边界。目标不是“永不失败”，而是每个失败都可识别、可恢复、可审计，且不会把未授权内容带入生成或发布链。

## 10.1 资产状态机

`AssetVersion` 只在 finalize 成功后创建且不可变；finalize 之前的主体是 `AssetUploadIntent` 与其物理对象。两条状态轴必须分开。

UploadIntent 仅有：

```text
initiated → uploaded → finalizing → finalized
initiated / uploaded / finalizing → aborted
initiated / uploaded → expired
```

只有 `finalized` intent 同时携带 `asset_version_id/finalized_at`；所有其他状态由 Schema 禁止这两个字段。`quarantined` 不是 UploadIntent 状态。

对象/资产可用性投影另有四个状态：

```text
staged ──validate + finalize──> finalized
   │                                │
   ├──validation/security fail──> quarantined
   └──lease timeout/no owner────> orphan

finalized ──post-finalize threat/rights incident──> quarantined availability projection
orphan ──reconcile proves ownership──> staged
```

- **`staged`**：UploadIntent 对应字节已进入隔离前缀，但尚无可引用的 `AssetVersion`；有短期 lease、声明的字节数/hash 和 uploader。
- **`finalized`**：数据库已创建不可变 `AssetVersion` 且与对象存储对象一致，校验、恶意媒体扫描和权利门均满足，允许按授权范围引用。
- **`quarantined`**：由独立 `ObjectQuarantine/AssetRestriction` 记录表达疑似恶意、内容类型不符、hash 不符、权利被撤销或事后安全事件；禁止进入生成、预览代理和发布。它不写回 UploadIntent 枚举，也不改写既有 `AssetVersion` 内容或血缘。
- **`orphan`**：没有可证明活动所有者的 staged 对象或残留 multipart upload；禁止引用，等待协调器恢复或清理。

删除是独立的 tombstone/retention 流程，不把 `deleted` 混成可恢复生产状态。

Availability/Restriction 每次变化都发布 outbox 事件。Release/Timeline/Generation 消费者按 `asset_version_id + availability_revision/hash` 建依赖；状态转为 `quarantined/restricted/deleted/orphan` 时，即使 AssetVersion 内容未变，也必须立即阻断代理、渲染、生成、发布并使所有依赖的 pre-render eligibility、ReleaseGate 和尚未提交的 PublishAttempt 失效。恢复为 available 只能创建新 projection revision 并重新求值，不能复活旧 Gate。

## 10.2 DB 与对象存储 finalize 协议

对象存储与 PostgreSQL 不能共享 ACID 事务，因此采用可协调的两阶段 finalize：

1. API 创建 `AssetUploadIntent`，分配 `upload_intent_id`、staging key、lease、最大大小和允许 MIME；此时不创建 `AssetVersion`。数据库事务提交后通过 outbox 发出意图事件。
2. 客户端只向 staging key 上传。服务端不信任扩展名或客户端 MIME。
3. Finalizer 流式读取并计算 SHA-256、实际大小、容器/编解码元数据；执行解压炸弹/畸形容器/恶意负载扫描和基础媒体解码。验证失败时 intent 进入 `aborted`；若需保留样本，独立创建 ObjectQuarantine 记录。
4. 在数据库事务中以 optimistic lock 把 intent 标为 `finalizing`，写入验证结果、content hash 和目标 key，并写 outbox；重复请求以 intent ID 为幂等键。
5. 通过对象存储的原子 copy/conditional put 把已验证对象写入 content-addressed final key；禁止覆盖已存在且 hash 不同的对象。
6. 再以 compare-and-set 在同一数据库事务中创建不可变 `AssetVersion`、将 UploadIntent 标为 `finalized` 并写出 `AssetFinalized` outbox 事件。只有此步完成后业务对象才能引用它；事后隔离通过独立 restriction/projection 表达，不修改该版本。
7. 协调器扫描 `finalizing`、过期 `staged` 和孤立 final object：按数据库意图补做、回滚为 `orphan` 或隔离；任何步骤都可幂等重放。

下载/处理时仍校验对象 metadata hash；关键发布路径重新计算 hash，防止后端或运维漂移。禁止把预签名 URL 当永久身份；持久层只存不可变 asset ID、object key、bucket 和 hash。

## 10.3 Hash、去重和租户授权边界

SHA-256 是完整性与去重索引，不是许可证明。默认只在同一项目安全域内物理去重：

- 同项目相同 hash 可复用底层 blob，但创建独立 `AssetVersion`、血缘和权利记录；
- 跨项目命中 hash 不能泄露“别的项目拥有该素材”，响应内容、状态码、大小分桶和可观测时延分布都必须与未命中一致；后台实际去重异步完成，避免用同步命中速度形成计时侧信道；
- 跨项目复用必须同时满足租户策略、共享素材库授权、用途/渠道/地域/期限许可兼容和数据驻留策略；
- 即使底层 blob 共享，每个项目仍需自己的逻辑引用和 rights snapshot；一方删除或撤权不能破坏另一方合法引用；
- 加密域或客户密钥不同则不得物理去重。

禁止依据感知 hash 自动判定素材相同或许可相同；感知 hash 只能用于重复候选提示或人工调查。

## 10.4 Inbox、Outbox 与外部回调

- 每个改变业务状态的数据库事务同时写 outbox；发布器可重复发送，消费者必须以 `event_id + consumer_name` 写 inbox 去重。
- Provider 请求包含稳定 `operation_id` 和 provider idempotency key；Attempt ID 唯一且追加式。
- ProviderRequestSnapshot 是加密、不可变的执行记录，Attempt 必填其 ID/hash；它保存去 secret 的 canonical payload hash 与解析输入，不得伪装成 AssetVersion 或候选媒体。
- 回调先验证签名、时间窗、nonce、来源和 payload 限额，再写 inbox；未知 operation、重复回调和已终止 Attempt 不改变当前状态。
- 迟到成功结果可登记为未采用资产，但不能覆盖较新的 Attempt 或 head pointer。
- 回调 URL、预签名 URL 和原始 payload 中的 token/secret 必须脱敏；原始响应按敏感级别加密并限制访问。
- 任何跨 DB/对象存储/队列的“恰好一次”承诺都实现为至少一次投递 + 幂等消费 + 对账，不依赖不可证明的分布式原子性。

## 10.5 保留、删除和法律保留

每类数据配置 `retention_class`：临时上传、Provider 原始响应、候选资产、已批准资产、发布资产、审计日志和权利证据分别定期。删除流程：

1. 创建带原因、发起人和范围的 `DeletionRequest`；
2. 计算引用、发布、审计和 legal hold；有阻断时不执行并给出机器可读原因；
3. 先撤销业务可见性并写 tombstone，再异步删除代理、缓存、派生物和底层 blob；
4. 共享 blob 只有在所有授权引用均消失且无保留义务时删除；
5. 记录不可逆删除证明，但不在审计中保留已要求删除的敏感正文；
6. 备份按固定窗口自然过期，并记录恢复后再次应用 tombstone 的机制。

权利撤销不等同于立即物理删除：系统先阻断生成、预览代理、时间线渲染、导出、发布和其他下游传播，并使相关 RenderInputManifest/ReleaseGate 失效，再按合同、法律保留和删除政策处理物理副本。

## 10.6 生成前 RightsGate

每个 GenerationAttempt 在向 Provider 发送任何字节或提示前，必须对精确输入集合和预期用途执行 `RightsGate`。至少覆盖：

- 输入剧本、图片、视频、字体及其他素材；
- 真人肖像、合成人物身份和角色授权；
- 声音样本、音色克隆、配音演员许可；
- 音乐、歌词、录音、采样和衍生音效；
- 目标 Provider 是否允许处理该素材，以及训练/留存/地域条款；
- 输出的渠道、地域、期限、商业用途和可衍生范围。

RightsGate 输入是不可变素材引用、rights-record revision、consent revision、Provider policy revision 和 intended-use snapshot；`schemas/rights-gate.schema.json` 输出 `allowed/blocked/manual_review`、逐项理由、有效期和 hash。任一输入、用途、Provider、许可 revision 或 expiry 改变都使结果失效。

`manual_review` 必须引用 Rights HumanTask，后者固定 required role、form schema、allowed actions、claim timeout、SLA 时间、唯一的 `hard_deadline_at` 和 escalation policy revision；不再保留语义重叠的 task `expires_at`。硬期限到达时进入 `deadline_expired` 并固定 `deadline_expired_at`，非到期状态禁止携带该字段。HumanTask action 不修改原 snapshot，而是触发重新求值并创建新的 allowed/blocked/manual snapshot。`blocked` 不得被 Adapter 降级成 warning。

ResolvedExecutionPlan 和 ProviderAttempt 都固定同一个 `allowed` snapshot ID/hash、expiry 与 intended-use hash。提交前再次比较：decision 必须 allowed、当前时间早于 expiry、intended-use hash 与 ProviderRequestSnapshot 相同；任何一项失败均不得发送字节。

RightsGate 不只用于 GenerationAttempt。创建 RenderInputManifest 和开始 RenderAttempt 前，Release Service 必须针对精确 Timeline 输入闭包与 `render/internal_export` intended use 重新求值：所有 Rights/consent 必须 `allowed` 且未过期，所有资产 availability 必须为 `available`，并把 snapshot ID/hash/expiry 与 availability snapshot hash 固定进 RenderInputManifest。渲染前再次比较；撤权/隔离事件使该清单失效。最终公开发布仍需对目标渠道/地域/期限执行独立 release RightsGate，不能复用渲染用途的允许结论。

许可传播遵循“最严格约束合取”：派生资产继承所有输入的用途、渠道、地域、期限、署名、再许可和 AI 处理限制；编译器只能保持或收紧，不能自动放宽。未知、冲突、过期或不可证明的许可默认为阻断/人工审核。生成模型声称“原创”不能消除输入许可或肖像/声音同意义务。

ReleaseGate 必须再次对最终时间线、导出版本和发布目标求值；生成前获准不代表公开发布获准。渲染前只创建 `RenderInputManifest`（Timeline/输入闭包/render profile）；export finalize、最终 QC 和发布 RightsGate 后才创建 `ReleaseManifest`（export/ReleaseGate/target/final hash）。PublishAttempt 固定 ReleaseManifest ID/hash 并追加执行；网络状态未知时按 submission key/远程 ID 对账，禁止盲目重发到平台。

## 10.7 Agent/MCP 写入边界

Agent、LLM 和 MCP 工具均按不可信调用者处理。它们不能直接写业务表、对象存储 final 前缀或 head pointer，只能提交：

- **Command**：调用已定义的窄业务动作，包含 actor/service identity、项目范围、目标 exact revision、幂等键和参数；
- **ChangeProposal**：对 Canonical 或高影响配置提出结构化 patch，包含基线 revision、理由、影响预览和所需审批。

Command handler 必须执行 schema validation、对象级授权、rights/policy gate、状态转换守卫、输入大小/URI allowlist、optimistic lock 和审计写入。冲突返回当前 revision，禁止 last-write-wins。高风险 proposal 需要人工批准，批准与应用分离，并在应用时重新校验基线与权限。

所有写入记录 `command_id/proposal_id`、调用主体、代表用户、工具/模型版本、输入 hash、验证结果、前后 revision、外部副作用和 trace ID。Secret 只通过受限 secret reference 注入，不进入 prompt、日志或资产 metadata。

## 10.8 Prompt injection 与恶意媒体

上传文本、字幕、网页、文档、图片 OCR、音频转写和视频画面都是数据，不是系统指令。防护要求：

- 系统/开发者指令与检索内容分通道，给外部内容加来源和不可信标签；
- 模型不得根据素材内指令扩大工具权限、访问其他项目、读取 secret 或绕过审批；
- 工具使用明确 allowlist、参数 schema、项目/对象 scope、最小权限和网络 egress policy；
- URL 取回阻断私网/metadata endpoint、重定向逃逸、非允许协议、超限响应和 DNS rebinding；
- 文档归档防路径穿越、符号链接、压缩炸弹和宏；媒体解析在无凭据、只读、资源限额的 sandbox 中；
- 对畸形容器、伪装 MIME、超大分辨率/帧率、解析器崩溃、隐写/可执行 payload 和安全扫描命中进入 `quarantined`；
- 给预览生成安全代理，审核员不直接打开原始未知文件；
- 模型输出再次按数据处理，未经验证不能变成 shell、SQL、模板、文件路径或 Provider 参数。

## 10.9 基线控制与审计

- 项目、角色和服务账号使用最小权限 RBAC/ABAC；审批、waiver、发布、权利修改和删除分别授权。
- 生产数据按租户隔离，传输和静态加密；敏感生物特征/声音样本使用更严格的访问与保留策略。
- 审计日志追加式并做 hash 链/周期签名；应用管理员也不能无痕修改。
- 供应商凭据分环境、定期轮换；日志和异常上报默认脱敏。
- 成本预算在发起 Attempt 前预留，完成后结算；超预算是可测试的阻断状态。
- 安全、权利和 Provider policy revision 是派生资产血缘的一部分，便于撤权影响分析和批量阻断。

## 10.10 最小故障演练

上线前至少自动化演练：上传中断、hash 不符、DB 提交后 copy 失败、copy 成功后 DB 失败、重复/乱序/伪造回调、恶意压缩包、畸形媒体、跨项目 hash 探测、乐观锁冲突、权限撤销、rights blocked/manual/过期、waiver 到期、预算 approval required、无 eligible route、ProviderRequestSnapshot hash 不符、删除与生成并发、PublishAttempt ACK 丢失/unknown remote、发布后权利撤销。每个演练必须证明状态可收敛且无越权引用或重复发布。
