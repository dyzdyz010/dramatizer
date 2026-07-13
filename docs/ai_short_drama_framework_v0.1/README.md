# AI 短剧生产框架设计文档

**版本：** v0.1  
**日期：** 2026-07-13  
**状态：** MVP 架构基线

本压缩包固化了 AI 短剧生产框架的整体项目说明、领域模型、系统架构、模型与技术选型、生产工作流、后期与质检体系、路线图、接口与 Stub 规范。

## 核心判断

本项目不是“输入提示词直接生成短剧”的工具，而是一个以**结构化叙事事实、导演意图、连续性状态和资产血缘**为权威数据的 AI 原生影视生产系统。

```text
结构化事实源
→ 模型无关的导演/生成中间表示
→ Provider 适配器
→ 提示词、参考素材和调用参数
→ 生成资产
→ 技术质检 + 原生视频理解 + CV + 叙事仲裁
→ 审核通过的时间线与成片
```

提示词和模型输出都是可重新生成的派生数据，不能反向污染权威事实源。

## 文档目录

| 文件 | 内容 |
|---|---|
| `AI_Short_Drama_Framework_Design_v0.1.docx` | 全部内容的合并阅读版 |
| `docs/01_project_overview.md` | 项目定位、目标、范围和设计原则 |
| `docs/02_domain_model.md` | 唯一事实源、核心实体、状态与版本模型 |
| `docs/03_system_architecture.md` | 总体架构、组件划分、部署与数据流 |
| `docs/04_model_and_technology_selection.md` | 模型分工、工程技术栈和能力缺口 |
| `docs/05_production_workflows.md` | 编剧、分镜、视频、音频、音效、后期完整流程 |
| `docs/06_quality_and_review.md` | Gemini 原生视频理解、CV、技术质检和叙事审核 |
| `docs/07_roadmap.md` | 从架构基线到完整 MVP 的里程碑与验收标准 |
| `docs/08_interfaces_and_stubs.md` | Provider 接口、能力状态、Stub 和人工接管协议 |
| `docs/09_architecture_decisions_and_risks.md` | 关键架构决策记录与风险控制 |
| `schemas/` | Canonical Shot、工作流节点、质量报告 Schema |
| `examples/` | 单集、镜头、模型路由、音频策略示例 |
| `diagrams/` | 架构图、生产 DAG、表示编译链源文件和 PNG |

## 当前确定的模型组合

- 叙事总策划与高层审核：Claude Opus 4.8
- 日常编剧与批量创作：Claude Sonnet 5
- 复杂推理与跨模型仲裁：GPT-5.6 Sol
- 结构化编译：GPT-5.6 Terra
- 高频分类与轻量检查：GPT-5.6 Luna
- 原生视频理解：Gemini（通过现有 API Key）
- 图像与关键帧：Seedream 5.0
- 视频与原生音频：Seedance 2.0
- 权威角色配音：GPT-SoVITS
- 音乐：Suno API Provider
- 媒体后期：FFmpeg / ffprobe
- 逐帧质检：OpenCV、MediaPipe、身份嵌入与可插拔 CV 分析器

## 推荐阅读顺序

1. `01_project_overview.md`
2. `02_domain_model.md`
3. `03_system_architecture.md`
4. `04_model_and_technology_selection.md`
5. `05_production_workflows.md`
6. `06_quality_and_review.md`
7. `07_roadmap.md`
8. `08_interfaces_and_stubs.md`
