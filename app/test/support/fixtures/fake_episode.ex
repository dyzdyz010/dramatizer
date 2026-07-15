defmodule Dramatizer.TestFixtures.FakeEpisode do
  alias Dramatizer.Generation

  def build_specs(project) do
    for shot_index <- 1..3, candidate_index <- 0..1 do
      shot_id = "S#{String.pad_leading(to_string(shot_index), 3, "0")}"

      {:ok, spec} =
        Generation.create_spec(project, %{
          kind: "shot_keyframe",
          candidate_index: candidate_index,
          formal: true,
          payload: %{
            "episode_id" => "E001",
            "scene_id" => "SC001",
            "shot_id" => shot_id,
            "width" => 540,
            "height" => 960,
            "prompt" => "#{shot_id} 竖屏静态关键帧"
          }
        })

      spec
    end
  end
end
