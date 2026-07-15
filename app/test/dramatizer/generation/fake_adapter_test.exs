defmodule Dramatizer.Generation.FakeAdapterTest do
  use Dramatizer.DataCase, async: true

  alias Dramatizer.Generation
  alias Dramatizer.Generation.Adapters.Fake
  alias Dramatizer.Projects

  test "same snapshot deterministically produces the same portrait PNG and declared cost" do
    assert {:ok, project} = Projects.create_project(%{name: "Fake Adapter"})

    assert {:ok, spec} =
             Generation.create_spec(project, %{
               kind: "shot_keyframe",
               candidate_index: 0,
               payload: %{"shot_id" => "S001", "width" => 540, "height" => 960}
             })

    assert {:ok, snapshot, attempt} =
             Generation.prepare_attempt(spec, :shot_keyframe, project, %{
               task_override: %{adapter: "fake", credential_ref: "none", model: "fake-v1"},
               request_input: %{
                 "generation_spec" => spec.payload,
                 "fault_profile" => %{"cost_micros" => 17}
               }
             })

    assert {:ok, first} = Fake.submit(snapshot, attempt)
    assert {:ok, second} = Fake.submit(snapshot, attempt)
    assert first.bytes == second.bytes
    assert first.mime_type == "image/png"
    assert first.width == 540
    assert first.height == 960
    assert first.cost_micros == 17
    assert byte_size(first.bytes) > 100
  end
end
