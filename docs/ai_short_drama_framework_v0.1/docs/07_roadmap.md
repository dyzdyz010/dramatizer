# 7. 实施路线图

路线图以“架构完整、逐层实现”为原则。每个阶段都必须保留完整接口、状态机和数据结构。

## M0：架构基线与仓库骨架

### 交付

- Monorepo 或清晰的多仓库边界；
- Canonical Schema v0.1；
- PostgreSQL 迁移；
- Asset Registry 和 MinIO；
- Workflow/Job 基础；
- Provider Registry；
- Fake/Stub Providers；
- 全链路追踪 ID；
- 基础权限和审计日志。

### 验收

不调用任何真实模型，也能用 Fake Provider 跑通：

```text
Project → Episode → Shot → GenerationTask → Asset → Review → Timeline → Export placeholder
```

## M1：叙事与结构化编译

### 交付

- 剧集圣经编辑器；
- 角色、场景、道具管理；
- Opus/Sonnet 创作工作流；
- Terra 编译 Episode/Scene/Beat/Shot；
- Luna 引用检查；
- Prompt/Generation IR；
- 版本与 stale 传播。

### 验收

一个故事创意能够生成一集经过人工审核的结构化剧本和镜头列表，所有引用可解析。

## M2：视觉预生产

### 交付

- Seedream Provider；
- 角色母版、多视图和服装版本；
- 场景、道具和分镜图；
- 关键帧锁定；
- Animatic；
- 候选比较和审核。

### 验收

无需视频生成即可输出带临时声音和字幕的完整分镜预演。

## M3：视频与声音主链

### 交付

- Seedance Provider；
- Seedance Native Audio；
- GPT-SoVITS Provider；
- 三种 Audio Strategy；
- Suno Music Provider；
- Seedance Derived SFX；
- 音频抽取、后处理和内部素材库；
- Generation Job 重试和恢复。

### 验收

可以为单集每个 Shot 生成、比较、批准视频和声音资产。

## M4：时间线、后期与质检

### 交付

- 多轨时间线；
- FFmpeg 导出；
- 句级字幕；
- 媒体技术 QC；
- Gemini Video Understanding；
- OpenCV/MediaPipe CV Worker；
- Opus/Sol 叙事审核；
- Quality Decision Engine；
- 人工审核工作台。

### 验收

能够输出一集 60-120 秒、10-30 个 Shot 的竖屏成片，并能从任意失败节点恢复。

## M5：完整 MVP 稳定化

### 交付

- 幂等和重放测试；
- 模型版本迁移；
- Provider 健康检测；
- 资产去重和代理缓存；
- 成本与采用率统计；
- 项目级阈值配置；
- 权限、审计和授权元数据；
- 端到端回归基准集。

### MVP 退出标准

- 一集完整闭环成功；
- 单 Shot 可独立重生成；
- 修改角色版本后能标记受影响资产；
- 原生音频和 GPT-SoVITS 两条路线都可运行；
- 质检报告能定位具体问题和时间区间；
- Stub 节点不会伪造成功；
- 所有最终成片资产可追溯到事实源和模型调用。

## M6：后续增强

- 专用口型修复 Provider；
- Forced Alignment Provider；
- 专用纯音效生成；
- 高级音源分离；
- 第二视频 Provider；
- 专用表演驱动；
- 多语言和自动配音版本；
- 反馈数据驱动的镜头路由；
- 自动基准测试和模型能力月度复核。

## 开发顺序约束

1. 先 Schema，后 UI；
2. 先 Fake Provider，后真实 Provider；
3. 先单 Shot 闭环，后整集批量；
4. 先资产血缘，后自动重生成；
5. 先技术 QC，后语义 QC；
6. 先人工可接管，后全自动化。
