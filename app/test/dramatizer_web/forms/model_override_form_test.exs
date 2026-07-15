defmodule DramatizerWeb.Forms.ModelOverrideFormTest do
  use ExUnit.Case, async: true

  alias DramatizerWeb.Forms.ModelOverrideForm

  test "casts image controls into provider params without JSON" do
    assert Code.ensure_loaded?(ModelOverrideForm)

    assert {:ok, attrs} =
             ModelOverrideForm.cast(:shot_keyframe, %{
               "model" => "gpt-image-2",
               "quality" => "high",
               "size" => "768x1360",
               "candidate_count" => "3"
             })

    assert attrs == %{
             model: "gpt-image-2",
             params: %{
               "candidate_count" => 3,
               "quality" => "high",
               "size" => "768x1360"
             }
           }
  end

  test "casts text controls and rejects invalid task-specific values" do
    assert Code.ensure_loaded?(ModelOverrideForm)

    assert {:ok, attrs} =
             ModelOverrideForm.cast(:narrative_proposal, %{
               "model" => "gpt-5.6-terra",
               "reasoning_effort" => "high"
             })

    assert attrs == %{
             model: "gpt-5.6-terra",
             params: %{"reasoning" => %{"effort" => "high"}}
           }

    assert {:error, errors} =
             ModelOverrideForm.cast(:reference_image, %{
               "quality" => "impossible",
               "size" => "wide",
               "candidate_count" => "0"
             })

    assert errors[:quality]
    assert errors[:size]
    assert errors[:candidate_count]
  end
end
