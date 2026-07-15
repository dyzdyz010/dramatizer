defmodule Dramatizer.Timeline.SRT do
  @moduledoc "Deterministic UTF-8 SubRip encoding."

  def encode(cues) do
    cues
    |> Enum.sort_by(&position/1)
    |> Enum.with_index(1)
    |> Enum.map_join("\n\n", fn {cue, index} ->
      "#{index}\n#{timestamp(value(cue, :start_ms))} --> #{timestamp(value(cue, :end_ms))}\n#{value(cue, :text)}"
    end)
    |> Kernel.<>("\n")
  end

  defp timestamp(milliseconds) do
    hours = div(milliseconds, 3_600_000)
    minutes = div(rem(milliseconds, 3_600_000), 60_000)
    seconds = div(rem(milliseconds, 60_000), 1_000)
    millis = rem(milliseconds, 1_000)

    :io_lib.format("~2..0B:~2..0B:~2..0B,~3..0B", [hours, minutes, seconds, millis])
    |> IO.iodata_to_binary()
  end

  defp position(value), do: value(value, :position)

  defp value(map, key) when is_map(map),
    do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
end
