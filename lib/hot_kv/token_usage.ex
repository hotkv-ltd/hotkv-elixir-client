# Copyright (c) 2026 HotKV Ltd
# Licensed under the Apache License, Version 2.0. See LICENSE in the project root.

defmodule HotKV.TokenUsage do
  @moduledoc """
  One model call's token usage: the "usage group" shared by `PCACHE.SET`,
  `SCACHE.SET`, every keyed cache `SET` (`TOOL.CACHE`/`NCACHE`/`GUARD`/
  `RERANK`) and `LLMBUDGET.CONSUME`. Recording a `TokenUsage` with a cache
  entry lets a later cache hit attribute its tokens, and once the model is
  priced its exact cost, to the namespace's `usage_saved_*` stats fields.

  `model` is required; every count defaults to `0` and is left off the
  wire when zero (`MODEL` itself is always sent once a `TokenUsage` is
  given).

      usage = HotKV.TokenUsage.new("claude-sonnet-5", input_tokens: 120, output_tokens: 40)
      HotKV.PromptCache.set(conn, ns, prompt, response, usage: usage)
  """

  @enforce_keys [:model]
  defstruct model: nil,
            input_tokens: 0,
            output_tokens: 0,
            cache_read_tokens: 0,
            cache_write_5m_tokens: 0,
            cache_write_1h_tokens: 0

  @type t :: %__MODULE__{
          model: String.t(),
          input_tokens: non_neg_integer,
          output_tokens: non_neg_integer,
          cache_read_tokens: non_neg_integer,
          cache_write_5m_tokens: non_neg_integer,
          cache_write_1h_tokens: non_neg_integer
        }

  @doc """
  Builds a `TokenUsage` for `model` (required, non-empty). `opts`:
  `:input_tokens`, `:output_tokens`, `:cache_read_tokens`,
  `:cache_write_5m_tokens`, `:cache_write_1h_tokens` (all default `0`).
  """
  @spec new(String.t(), keyword) :: t
  def new(model, opts \\ []) when is_binary(model) and model != "" do
    %__MODULE__{
      model: model,
      input_tokens: Keyword.get(opts, :input_tokens, 0),
      output_tokens: Keyword.get(opts, :output_tokens, 0),
      cache_read_tokens: Keyword.get(opts, :cache_read_tokens, 0),
      cache_write_5m_tokens: Keyword.get(opts, :cache_write_5m_tokens, 0),
      cache_write_1h_tokens: Keyword.get(opts, :cache_write_1h_tokens, 0)
    }
  end

  @doc false
  # The `MODEL model [INPUT n] [OUTPUT n] [CACHEREAD n] [CACHEWRITE5M n]
  # [CACHEWRITE1H n]` trailing options this usage value adds to a
  # command's argument list, appended to `acc`. `nil` is a no-op (the
  # command behaves exactly as if no usage was given); a non-nil `t`
  # always sends `MODEL`, followed only by the non-zero counts, in this
  # fixed order.
  @spec args([term], t | nil) :: [term]
  def args(acc, nil), do: acc

  def args(acc, %__MODULE__{} = usage) do
    acc = acc ++ ["MODEL", usage.model]
    acc = maybe_count(acc, "INPUT", usage.input_tokens)
    acc = maybe_count(acc, "OUTPUT", usage.output_tokens)
    acc = maybe_count(acc, "CACHEREAD", usage.cache_read_tokens)
    acc = maybe_count(acc, "CACHEWRITE5M", usage.cache_write_5m_tokens)
    maybe_count(acc, "CACHEWRITE1H", usage.cache_write_1h_tokens)
  end

  defp maybe_count(acc, _token, 0), do: acc
  defp maybe_count(acc, token, count), do: acc ++ [token, count]
end
