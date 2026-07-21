defmodule Dramatizer.Generation.StructuredTextProposal do
  @moduledoc "Runs versioned Narrative, VisualDesign, and Directing proposals through the persisted provider contract."

  import Ecto.Query

  alias Dramatizer.CanonicalJSON
  alias Dramatizer.Costs
  alias Dramatizer.Generation
  alias Dramatizer.Generation.{Attempt, ProposalSchemas}
  alias Dramatizer.Generation.Adapters.OpenAIResponses
  alias Dramatizer.Projects
  alias Dramatizer.Projects.Project
  alias Dramatizer.Prompts.Composer
  alias Dramatizer.Repo

  @tasks ~w(narrative_proposal visual_design_proposal directing_proposal)a

  def propose(%Project{} = project, task_type, authority, opts \\ [])
      when task_type in @tasks and is_map(authority) do
    mode = Keyword.get(opts, :provider_mode, Application.fetch_env!(:dramatizer, :provider_mode))
    schema = ProposalSchemas.fetch!(task_type)
    appendix = Projects.current_prompt_appendix(project, task_type)

    input_json =
      CanonicalJSON.encode(%{
        "authority" => authority,
        "instruction" => task_instruction(task_type)
      })

    with {:ok, prompt} <- Composer.compose(task_type, appendix, %{input_json: input_json}),
         {:ok, spec} <-
           Generation.create_spec(project, %{
             kind: "#{task_type}_proposal",
             formal: false,
             payload: %{
               "task_type" => Atom.to_string(task_type),
               "authority_hash" => CanonicalJSON.hash(authority),
               "prompt_content_hash" => prompt.content_hash,
               "schema_hash" => CanonicalJSON.hash(schema)
             }
           }),
         {:ok, snapshot, _attempt} <-
           Generation.prepare_attempt(spec, task_type, project, %{
             task_override: task_override(mode, Keyword.get(opts, :task_override, %{})),
             request_input: %{
               "input" => prompt.content,
               "schema_name" => ProposalSchemas.name(task_type),
               "schema" => schema,
               "authority_hash" => CanonicalJSON.hash(authority)
             },
             prompt_snapshot: %{
               "core_version" => prompt.core_version,
               "core_hash" => prompt.core_hash,
               "appendix_revision_id" => prompt.appendix_revision_id,
               "appendix_revision" => prompt.appendix_revision,
               "appendix_hash" => prompt.appendix_hash,
               "content_hash" => prompt.content_hash,
               "schema_hash" => CanonicalJSON.hash(schema)
             }
           }),
         {:ok, attempt} <- runnable_attempt(snapshot) do
      dispatch(project, task_type, snapshot, attempt, mode, opts)
    end
  end

  defp dispatch(_project, _task, snapshot, %Attempt{status: :succeeded} = attempt, _mode, _opts) do
    case attempt.response_metadata["proposal_output"] do
      output when is_map(output) -> {:ok, result(output, snapshot, attempt)}
      _ -> {:error, :proposal_output_missing_from_succeeded_attempt}
    end
  end

  defp dispatch(project, task, snapshot, %Attempt{status: :prepared} = attempt, mode, opts) do
    with {:ok, reservation} <- reserve(project, snapshot, attempt, mode),
         {:ok, submitted} <- Generation.transition_attempt(attempt, :submitted) do
      submitter = Keyword.get(opts, :submitter, submitter(mode, task))

      case submitter.(snapshot, submitted) do
        {:ok, provider_result} ->
          complete_success(task, snapshot, submitted, provider_result, reservation)

        {:error, code, metadata} ->
          Costs.settle_provider_attempt(reservation, nil, %{
            provider: Atom.to_string(mode),
            status: to_string(code)
          })

          Generation.record_submission_error(submitted, code, metadata, mode)
      end
    end
  end

  defp dispatch(_project, _task, _snapshot, %Attempt{status: status}, _mode, _opts),
    do: {:error, {:proposal_attempt_not_runnable, status}}

  defp complete_success(task, snapshot, attempt, provider_result, reservation) do
    case ProposalSchemas.validate(task, Map.get(provider_result, :output)) do
      {:ok, output} ->
        with :ok <-
               Costs.settle_provider_attempt(
                 reservation,
                 Map.get(provider_result, :cost_micros),
                 %{
                   provider: snapshot.adapter,
                   request_id: Map.get(provider_result, :request_id)
                 }
               ),
             {:ok, succeeded} <-
               Generation.transition_attempt(attempt, :succeeded, %{
                 external_request_id: Map.get(provider_result, :external_request_id),
                 response_metadata: %{
                   "proposal_output" => output,
                   "proposal_output_hash" => CanonicalJSON.hash(output),
                   "request_id" => Map.get(provider_result, :request_id),
                   "usage" => Map.get(provider_result, :usage, %{})
                 }
               }) do
          {:ok, result(output, snapshot, succeeded)}
        end

      {:error, validation_errors} ->
        Costs.settle_provider_attempt(reservation, nil, %{
          provider: snapshot.adapter,
          status: "invalid_output"
        })

        Generation.transition_attempt(attempt, :failed, %{
          error_code: "invalid_proposal_output",
          error_message: "invalid_proposal_output",
          response_metadata: %{"validation_errors" => stringify(validation_errors)}
        })

        {:error, :invalid_proposal_output}
    end
  end

  defp result(output, snapshot, attempt) do
    %{output: output, request_snapshot: snapshot, attempt: attempt}
  end

  defp runnable_attempt(snapshot) do
    latest =
      Repo.one!(
        from attempt in Attempt,
          where: attempt.provider_request_snapshot_id == ^snapshot.id,
          order_by: [desc: attempt.attempt_number],
          limit: 1
      )

    case latest.status do
      status when status in [:failed, :timed_out] -> Generation.retry_attempt(latest)
      _ -> {:ok, latest}
    end
  end

  defp reserve(_project, _snapshot, _attempt, :fake), do: {:ok, nil}

  defp reserve(project, snapshot, attempt, :openai),
    do: Costs.reserve_provider_attempt(project, snapshot, attempt, :openai)

  defp submitter(:openai, _task), do: &OpenAIResponses.submit/2

  defp submitter(:fake, task) do
    fn snapshot, _attempt ->
      {:ok,
       %{
         output: fake_output(task),
         external_request_id: "fake-#{task}-#{snapshot.id}",
         request_id: "fake-#{task}-#{snapshot.id}",
         usage: %{}
       }}
    end
  end

  defp task_override(:openai, override), do: override

  defp task_override(:fake, override) do
    override
    |> Map.new()
    |> Map.merge(%{adapter: "fake", credential_ref: "none", model: "fake-text-v2"})
  end

  defp task_instruction(:narrative_proposal),
    do: "形成 Scene、Beat、StoryEvent、DialogueEvent 与来源语义明确的分集叙事 Draft。"

  defp task_instruction(:visual_design_proposal),
    do: "补全角色、场景、道具、VisualVariant、参考要求、必须项和禁止项。"

  defp task_instruction(:directing_proposal),
    do: "形成逐镜呈现目标、摄影、调度、声音、连续性、时长与约束。"

  defp fake_output(:narrative_proposal) do
    %{
      "schema_version" => "narrative-draft-v2",
      "episode" => %{
        "id" => "episode:001",
        "title" => "雨夜来信",
        "logline" => "林夏在雨夜车站收到一封不该出现的匿名信。",
        "summary" => "匿名信打破林夏原本的平静，并暗示寄信人仍在附近。",
        "opening_hook" => "一封湿透却字迹清晰的信出现在空座上。",
        "central_conflict" => "林夏必须判断信中警告是真相还是诱饵。",
        "ending_hook" => "她抬头时看见远处的人影消失。"
      },
      "scenes" => [
        %{
          "id" => "SC001",
          "title" => "雨夜车站",
          "location_ref" => "location:station",
          "time_of_day" => "夜",
          "goal" => "建立悬疑并让匿名信进入人物行动线。",
          "summary" => "林夏在空旷站台发现匿名信并意识到寄信人可能在附近。",
          "source_semantics" => "source_grounded",
          "beats" => [
            %{
              "id" => "B001",
              "title" => "发现匿名信",
              "goal" => "把注意力集中到不寻常的信件。",
              "summary" => "林夏发现并拆开信。",
              "story_event_ids" => ["EV001"]
            }
          ]
        }
      ],
      "story_events" => [
        %{
          "id" => "EV001",
          "name" => "收到匿名信",
          "description" => "林夏在车站发现一封指向未知危险的匿名信。",
          "subject_refs" => ["person:lead", "prop:letter"],
          "source_semantics" => "source_grounded"
        }
      ],
      "dialogue_events" => [
        %{
          "id" => "D001",
          "speaker_ref" => "person:lead",
          "text" => "这封信，不该出现在这里。",
          "scene_id" => "SC001",
          "beat_id" => "B001",
          "story_event_id" => "EV001",
          "source_semantics" => "creative",
          "start_ms" => 150,
          "end_ms" => 1_800
        }
      ],
      "dependencies" => [
        %{
          "id" => "person:lead",
          "kind" => "person",
          "name" => "林夏",
          "source_semantics" => "source_grounded"
        },
        %{
          "id" => "location:station",
          "kind" => "location",
          "name" => "雨夜车站",
          "source_semantics" => "source_grounded"
        },
        %{
          "id" => "prop:letter",
          "kind" => "prop",
          "name" => "匿名信",
          "source_semantics" => "source_grounded"
        }
      ],
      "conflicts" => [],
      "production_profile_override" => %{
        "aspect_width" => nil,
        "aspect_height" => nil,
        "duration_min_seconds" => nil,
        "duration_max_seconds" => nil,
        "shot_min" => nil,
        "shot_max" => nil
      }
    }
  end

  defp fake_output(:visual_design_proposal) do
    %{
      "schema_version" => "visual-design-draft-v2",
      "objects" => [
        %{
          "id" => "character:linxia",
          "type" => "character",
          "name" => "林夏",
          "narrative_role" => "克制而敏锐的主角",
          "importance" => "key",
          "recurring" => true,
          "key" => true,
          "reference_required" => true,
          "source_semantics" => "creative",
          "description" => "二十多岁，短黑发，冷静克制，深色通勤风衣。",
          "palette" => ["炭黑", "冷灰", "暗橙"],
          "materials" => ["哑光防水面料"],
          "must_show" => ["短黑发", "深色风衣"],
          "must_not_show" => ["夸张妆容"],
          "variants" => [
            %{
              "id" => "raincoat",
              "name" => "雨夜风衣",
              "state_description" => "衣肩被雨水打湿",
              "wardrobe" => "深色通勤风衣",
              "lighting" => "冷色站台顶灯",
              "required_slots" => ["face_closeup", "three_quarter_full", "expression_features"]
            }
          ]
        },
        %{
          "id" => "location:station",
          "type" => "location",
          "name" => "雨夜车站",
          "narrative_role" => "孤立且充满反光的悬疑空间",
          "importance" => "key",
          "recurring" => true,
          "key" => true,
          "reference_required" => true,
          "source_semantics" => "creative",
          "description" => "空旷旧车站，金属顶棚和湿漉漉站台形成纵深。",
          "palette" => ["蓝灰", "墨绿", "钠灯橙"],
          "materials" => ["湿混凝土", "旧金属"],
          "must_show" => ["站台雨水反光"],
          "must_not_show" => ["拥挤人群"],
          "variants" => [
            %{
              "id" => "rainy_night",
              "name" => "雨夜",
              "state_description" => "持续降雨，远处有薄雾",
              "wardrobe" => "",
              "lighting" => "冷顶灯与远处暖光",
              "required_slots" => ["spatial_wide", "primary_direction", "key_lighting"]
            }
          ]
        },
        %{
          "id" => "prop:letter",
          "type" => "prop",
          "name" => "匿名信",
          "narrative_role" => "推动悬疑的关键道具",
          "importance" => "key",
          "recurring" => true,
          "key" => true,
          "reference_required" => true,
          "source_semantics" => "creative",
          "description" => "略微泛黄的旧纸信封，边缘有雨水浸湿痕迹。",
          "palette" => ["旧纸黄", "深褐"],
          "materials" => ["粗纤维纸"],
          "must_show" => ["雨水浸湿边缘"],
          "must_not_show" => ["现代快递标签"],
          "variants" => [
            %{
              "id" => "sealed_wet",
              "name" => "湿封状态",
              "state_description" => "信封密封且边缘湿润",
              "wardrobe" => "",
              "lighting" => "冷光下可见纸张纹理",
              "required_slots" => ["overall", "key_detail_state"]
            }
          ]
        }
      ]
    }
  end

  defp fake_output(:directing_proposal) do
    %{
      "schema_version" => "shot-plan-draft-v2",
      "scenes" => [%{"id" => "SC001", "name" => "雨夜车站", "purpose" => "建立悬疑并完成匿名信发现"}],
      "shots" => [
        fake_shot(
          "S001",
          "环境建立",
          "环境建立镜头展示孤立站台与林夏",
          "ENVIRONMENT_ESTABLISHING",
          "static",
          1_500,
          2_000,
          2_800
        ),
        fake_shot(
          "S002",
          "发现细节",
          "推进到匿名信与林夏的反应",
          "OBJECT_INSERT",
          "push_in",
          1_400,
          1_800,
          2_500
        ),
        fake_shot("S003", "确认威胁", "林夏抬头确认远处人影已经离开", "REACTION", "pull_out", 1_300, 1_700, 2_300)
      ],
      "sound_strategy" => "silent_placeholder",
      "continuity" => %{"track" => "main_narrative", "notes" => "匿名信从座椅转移到林夏右手，服装与雨湿状态连续。"}
    }
  end

  defp fake_shot(id, goal, description, class, movement, minimum, preferred, maximum) do
    %{
      "id" => id,
      "scene_id" => "SC001",
      "beat_id" => "B001",
      "story_event_ids" => ["EV001"],
      "presentation_goal" => goal,
      "description" => description,
      "shot_class" => class,
      "coverage" => "complete",
      "minimum_duration_ms" => minimum,
      "preferred_duration_ms" => preferred,
      "maximum_duration_ms" => maximum,
      "timing_rationale" => "确保动作与情绪变化可读。",
      "camera" => %{
        "shot_size" => "中景",
        "angle" => "平视",
        "movement" => movement,
        "visual_focus" => "林夏与匿名信",
        "composition_notes" => "保持竖屏主体清晰并留出字幕安全区。",
        "lens_intent" => "轻微压缩空间，避免广角畸变。"
      },
      "staging" => %{
        "location_ref" => "location:station/rainy_night",
        "participant_refs" => ["character:linxia/raincoat"],
        "prop_refs" => ["prop:letter/sealed_wet"],
        "blocking_notes" => "林夏站在座椅旁，右手拿信。"
      },
      "audio_strategy" => %{
        "mode" => "narrative_dialogue",
        "dialogue_event_ids" => ["D001"],
        "sound_notes" => "首版使用静音占位。"
      },
      "continuity" => %{
        "start_state" => ["林夏右手持信"],
        "actions" => ["视线从信移向远处"],
        "end_state" => ["林夏保持右手持信"],
        "relation_to_previous" => "continuous"
      },
      "constraints" => %{
        "must_show" => ["匿名信", "雨夜站台"],
        "must_not_show" => ["第三人清晰正脸"],
        "reference_object_ids" => ["character:linxia", "location:station", "prop:letter"]
      }
    }
  end

  defp stringify(value) when is_map(value),
    do: Map.new(value, fn {key, nested} -> {to_string(key), stringify(nested)} end)

  defp stringify(value) when is_list(value), do: Enum.map(value, &stringify/1)
  defp stringify(value) when value in [true, false, nil], do: value
  defp stringify(value) when is_atom(value), do: Atom.to_string(value)
  defp stringify(value), do: value
end
