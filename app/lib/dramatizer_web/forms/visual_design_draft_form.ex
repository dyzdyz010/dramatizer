defmodule DramatizerWeb.Forms.VisualDesignDraftForm do
  @moduledoc "Version-aware form adapter for editable VisualDesign authority drafts."

  alias DramatizerWeb.Forms.FormSupport, as: F

  @slots %{
    "character" => ~w(face_closeup three_quarter_full expression_features),
    "location" => ~w(spatial_wide primary_direction key_lighting),
    "prop" => ~w(overall key_detail_state)
  }

  def from_payload(payload) do
    payload = F.string_keys(payload || %{})

    Map.update(payload, "objects", [], fn objects ->
      Enum.map(objects, fn object ->
        object
        |> encode_fields(~w(palette materials must_show must_not_show))
        |> Map.update("variants", [], fn variants ->
          Enum.map(variants, &encode_fields(&1, ["required_slots"]))
        end)
      end)
    end)
  end

  def cast(params, current) when is_map(params) and is_map(current) do
    params = F.string_keys(params)
    current = F.string_keys(current)

    objects =
      F.cast_collection(
        Map.get(params, "objects", Map.get(current, "objects", [])),
        current["objects"],
        &cast_object/2
      )

    payload =
      F.merge_preserving(current, %{
        "schema_version" => "visual-design-draft-v2",
        "objects" => objects
      })

    errors = validate(objects)
    if errors == %{}, do: {:ok, payload}, else: {:error, errors}
  end

  def add(payload, collection, item), do: F.add(payload, collection, item)
  def remove(payload, collection, id), do: F.remove(payload, collection, id)
  def move(payload, collection, id, direction), do: F.move(payload, collection, id, direction)

  defp cast_object(params, current) do
    type = F.value(params, current, "type", "character")
    type = if Map.has_key?(@slots, type), do: type, else: "character"
    recurring = F.boolean(F.value(params, current, "recurring", false))
    key = F.boolean(F.value(params, current, "key", false))

    reference_required =
      if Map.has_key?(params, "reference_required") do
        F.boolean(params["reference_required"])
      else
        Map.get(current, "reference_required", recurring or key)
      end

    variants =
      F.cast_collection(
        Map.get(params, "variants", Map.get(current, "variants", [])),
        current["variants"],
        fn variant, old_variant ->
          slots =
            F.text_list(F.value(variant, old_variant, "required_slots", Map.fetch!(@slots, type)))

          F.merge_preserving(old_variant, %{
            "id" => F.id(variant, old_variant, "VAR"),
            "name" => F.value(variant, old_variant, "name", "默认状态"),
            "state_description" => F.value(variant, old_variant, "state_description"),
            "wardrobe" => F.value(variant, old_variant, "wardrobe"),
            "lighting" => F.value(variant, old_variant, "lighting"),
            "required_slots" => slots
          })
        end
      )

    variants =
      if variants == [] do
        [
          %{
            "id" => "default",
            "name" => "默认状态",
            "state_description" => "",
            "wardrobe" => "",
            "lighting" => "",
            "required_slots" => Map.fetch!(@slots, type)
          }
        ]
      else
        variants
      end

    F.merge_preserving(current, %{
      "id" => F.id(params, current, String.upcase(type)),
      "type" => type,
      "name" => F.value(params, current, "name"),
      "narrative_role" => F.value(params, current, "narrative_role"),
      "importance" => importance(F.value(params, current, "importance", "supporting")),
      "recurring" => recurring,
      "key" => key,
      "reference_required" => reference_required,
      "source_semantics" => semantics(F.value(params, current, "source_semantics")),
      "description" => F.value(params, current, "description"),
      "palette" => F.text_list(F.value(params, current, "palette", [])),
      "materials" => F.text_list(F.value(params, current, "materials", [])),
      "must_show" => F.text_list(F.value(params, current, "must_show", [])),
      "must_not_show" => F.text_list(F.value(params, current, "must_not_show", [])),
      "variants" => variants
    })
  end

  defp validate(objects) do
    errors = %{}

    errors =
      if objects != [] and F.unique_ids?(objects),
        do: errors,
        else: F.put_error(errors, :objects, "至少需要一个对象，且对象 ID 必须唯一")

    Enum.reduce(objects, errors, fn object, acc ->
      acc
      |> require_object(object)
      |> require_variants(object)
      |> reject_constraint_conflicts(object)
    end)
  end

  defp require_object(errors, object) do
    if F.required?(object["name"]) and F.required?(object["description"]),
      do: errors,
      else: F.put_error(errors, :objects, "对象名称和设计描述不能为空")
  end

  defp require_variants(errors, object) do
    variants = object["variants"] || []

    valid =
      variants != [] and F.unique_ids?(variants) and
        Enum.all?(variants, fn variant ->
          F.required?(variant["name"]) and
            (not object["reference_required"] or variant["required_slots"] != [])
        end)

    if valid,
      do: errors,
      else: F.put_error(errors, :objects, "每个对象需要唯一、完整的状态与参考槽位")
  end

  defp reject_constraint_conflicts(errors, object) do
    case F.conflicts(object["must_show"], object["must_not_show"]) do
      [] -> errors
      conflicts -> F.put_error(errors, :objects, "必须出现与禁止出现冲突：#{Enum.join(conflicts, "、")}")
    end
  end

  defp encode_fields(item, fields) do
    Enum.reduce(fields, item, fn field, acc ->
      Map.update(acc, field, "", fn value -> F.text_list_input(value) end)
    end)
  end

  defp importance(value) when value in ~w(background supporting key), do: value
  defp importance(_value), do: "supporting"

  defp semantics(value) when value in ~w(source_grounded inferred creative), do: value
  defp semantics(_value), do: "source_grounded"
end
