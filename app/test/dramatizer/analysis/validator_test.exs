defmodule Dramatizer.Analysis.ValidatorTest do
  use ExUnit.Case, async: true

  alias Dramatizer.Analysis.Validator

  @source_id "11111111-1111-1111-1111-111111111111"

  test "validates strict schema, source semantics, locators, references, uniqueness, and ranges" do
    valid = %{
      "items" => [
        item("person:p1", "source_grounded", [locator(0, 2)]),
        item("person:p2", "inferred", [locator(4, 6)], ["person:p1"]),
        item("wardrobe:w1", "creative", [])
      ]
    }

    assert {:ok, ^valid} =
             Validator.validate(:people_relations, valid, source_revision_ids: [@source_id])
  end

  test "returns stable JSON-pointer errors for invalid JSON, missing locators, and dangling references" do
    assert {:error, [%{code: :invalid_json, path: "/"}]} =
             Validator.validate(:people_relations, "{bad")

    invalid = %{
      "items" => [
        item("person:p1", "source_grounded", [], ["missing:id"]),
        item("person:p1", "creative", [])
      ]
    }

    assert {:error, errors} =
             Validator.validate(:people_relations, invalid, source_revision_ids: [@source_id])

    assert %{code: :locator_required, path: "/items/0/locators"} in errors
    assert %{code: :dangling_reference, path: "/items/0/references/0"} in errors
    assert %{code: :duplicate_id, path: "/items/1/id"} in errors

    bad_range = %{"items" => [item("event:e1", "inferred", [locator(9, 2)])]}
    assert {:error, range_errors} = Validator.validate(:events_timeline, bad_range)
    assert %{code: :invalid_range, path: "/items/0/locators/0"} in range_errors
  end

  test "schema rejects unknown fields before domain validation" do
    invalid = %{"items" => [Map.put(item("person:p1", "creative", []), "invented", true)]}
    assert {:error, [first | _]} = Validator.validate(:people_relations, invalid)
    assert first.code == :additional_property
    assert first.path == "/items/0/invented"
  end

  defp item(id, semantics, locators, references \\ []) do
    %{
      "id" => id,
      "kind" => id |> String.split(":") |> hd(),
      "name" => id,
      "source_semantics" => semantics,
      "locators" => locators,
      "references" => references,
      "data" => %{}
    }
  end

  defp locator(start_offset, end_offset) do
    %{
      "source_revision_id" => @source_id,
      "start_offset" => start_offset,
      "end_offset" => end_offset
    }
  end
end
