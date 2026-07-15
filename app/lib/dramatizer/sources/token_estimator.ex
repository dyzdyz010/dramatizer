defmodule Dramatizer.Sources.TokenEstimator do
  @moduledoc "Conservative versioned preflight for the whole-document strategy."

  @version "whole-document-v1"

  def preflight(text, resolved_model, reserved_tokens)
      when is_binary(text) and is_integer(reserved_tokens) and reserved_tokens >= 0 do
    with {:ok, model, context_window} <- resolve_context(resolved_model) do
      measured_tokens = div(byte_size(text) + 2, 3)
      total_tokens = measured_tokens + reserved_tokens

      details = %{
        estimator_version: @version,
        strategy: :whole_document,
        model: model,
        measured_tokens: measured_tokens,
        reserved_tokens: reserved_tokens,
        total_tokens: total_tokens,
        context_window: context_window,
        available_document_tokens: max(0, context_window - reserved_tokens),
        document_bytes: byte_size(text),
        truncated: false,
        chunked: false
      }

      if total_tokens <= context_window do
        {:ok, details}
      else
        {:error, :document_too_large, details}
      end
    end
  end

  defp resolve_context(%{model: model, context_window: context})
       when is_binary(model) and is_integer(context) and context > 0,
       do: {:ok, model, context}

  defp resolve_context(%{"model" => model, "context_window" => context})
       when is_binary(model) and is_integer(context) and context > 0,
       do: {:ok, model, context}

  defp resolve_context(model) when is_binary(model) do
    case Application.fetch_env!(:dramatizer, :model_context_windows)[model] do
      context when is_integer(context) and context > 0 -> {:ok, model, context}
      _ -> {:error, :unknown_model_context}
    end
  end

  defp resolve_context(_resolved_model), do: {:error, :unknown_model_context}
end
