# 2. 领域模型与唯一事实源

## 2.1 聚合层级

```text
Project
└── SeriesBible
    └── Season
        └── Episode
            └── Scene
                └── Beat
                    └── Shot
```

- **Project**：生产项目、成员、默认风格、预算和发布目标。
- **SeriesBible**：世界观、人物关系、视觉规则和长期叙事约束。
- **Season**：整季主题、主线和人物弧。
- **Episode**：单集目标、钩子、冲突、反转和悬念。
- **Scene**：时间与地点连续的场景单元。
- **Beat**：一次信息、行动或情绪状态变化。
- **Shot**：最终生成、审核、替换和剪辑的最小生产单元。

## 2.2 三层表示

### 语义事实层

只描述世界中发生的事实：

```json
{
  "actor": "char_lin",
  "action": "pick_up",
  "object": "prop_contract_01",
  "hand": "right",
  "emotion_transition": ["calm", "suspicious"]
}
```

### 导演表达层

描述如何呈现事实：

```json
{
  "shot_size": "medium_close_up",
  "camera_movement": "slow_push_in",
  "visual_focus": "eyes_and_contract_seal",
  "performance_intensity": 0.45,
  "duration_ms": 4500
}
```

### 模型执行层

由编译器生成，不进入权威领域模型：

```json
{
  "provider": "seedance",
  "model": "seedance-2.0",
  "prompt": "...",
  "reference_assets": ["asset://char_lin_v5", "asset://meeting_room_v2"],
  "duration_seconds": 5,
  "aspect_ratio": "9:16"
}
```

## 2.3 核心实体

### 叙事实体

- `SeriesBible`
- `Character`
- `CharacterVersion`
- `Relationship`
- `Location`
- `LocationVersion`
- `Prop`
- `PropVersion`
- `Wardrobe`
- `WardrobeVersion`
- `Episode`
- `Scene`
- `Beat`
- `Shot`
- `Dialogue`

### 生产实体

- `Asset`
- `AssetVersion`
- `GenerationTask`
- `ModelRun`
- `WorkflowRun`
- `Review`
- `QualityReport`
- `Timeline`
- `TimelineVersion`
- `Release`

## 2.4 Shot 是核心边界

Shot 至少包含以下信息：

```json
{
  "id": "ep01_sc03_sh05",
  "scene_id": "ep01_sc03",
  "shot_class": "DIALOGUE_CLOSEUP",
  "narrative_purpose": "女主识别合同异常并形成压迫感",
  "duration_ms": 4500,
  "characters": [
    {
      "character_version_id": "char_lin_v5",
      "wardrobe_version_id": "wardrobe_office_gray_v2",
      "pose": "seated",
      "gaze_target": "char_zhou",
      "emotion": "restrained_anger"
    }
  ],
  "camera": {
    "shot_size": "medium_close_up",
    "angle": "eye_level",
    "movement": "slow_push_in"
  },
  "audio_strategy": "gpt_sovits_first",
  "planned_state": {},
  "approval_status": "draft"
}
```

## 2.5 连续性状态

每个 Shot 包含：

- `start_state`：镜头开始时的角色、场景和道具状态；
- `actions`：镜头中发生的状态转换；
- `end_state`：计划中的结束状态；
- `detected_state`：从输出中检测到的实际状态；
- `approved_state`：审核后作为下一镜头输入的状态。

状态链为：

```text
上一镜头 approved_end_state
→ 当前镜头 start_state
→ actions
→ planned_end_state
→ detected_end_state
→ approved_end_state
→ 下一镜头
```

## 2.6 版本与不可变资产

建议采用不可变版本模型：

- 修改角色母版不会覆盖旧版本，而是创建 `CharacterVersion`；
- 修改关键帧会创建新 `AssetVersion`；
- 修改镜头会创建新 `ShotRevision`；
- 成片时间线引用明确版本，不引用“最新版本”这种浮动目标。

依赖变化时，系统标记派生产物为 stale：

```text
角色服装版本变化
→ Prompt IR stale
→ Keyframe stale
→ Video stale
→ Timeline warning
```

是否重新生成由用户或策略决定。

## 2.7 资产血缘

每个 `AssetVersion` 记录：

- `source_type`：generated / uploaded / extracted / derived；
- `parent_asset_ids`；
- `generation_run_id`；
- `provider` 和 `model_version`；
- `prompt_ir_version`；
- `request_payload_hash`；
- `content_hash`；
- `license_metadata`；
- `approval_status`。

示例：

```text
最终镜头视频 v4
├── Seedance 生成任务 run_882
├── 首帧 asset_keyframe_v3
│   ├── 角色母版 char_lin_v5
│   └── 场景母版 room_v2
├── GPT-SoVITS 对白 audio_v2
└── Shot Revision 7
```

## 2.8 审核状态

建议统一状态机：

```text
draft
→ ready_for_generation
→ generating
→ generated
→ qc_failed / qc_warning / ready_for_review
→ approved / rejected / repair_required / regenerate_required
→ included_in_timeline
→ released
```

任何模型输出都不能直接进入 `approved`。
