# Copyright (c) 2026 HotKV Ltd
# Licensed under the Apache License, Version 2.0. See LICENSE in the project root.

defmodule HotKV.AI.PromptCache do
  @moduledoc """
  An idiomatic get-or-call cache in front of `PCACHE.*` (`HotKV.PromptCache`):
  on a cache hit it returns the stored response without calling the LLM; on
  a miss, it calls the caller's function, stores the result, and returns
  it. The cache key is `HotKV.AI.PromptCacheKey.build/1`'s canonical,
  cross-SDK key.

  Needs a server license that includes the prompt-cache feature; if the namespace is
  unavailable because of that (a `NOLICENSE` reply), `get_or_call/3` treats
  it as a cache miss and calls through, rather than failing the request
  (the cache being unavailable should never be why an LLM call fails).

      pc = HotKV.AI.PromptCache.new(conn, "chat_cache", ttl: 3600, stats_bucket: "chat")
      :ok = HotKV.AI.PromptCache.create_namespace(pc)

      {:ok, response, hit?} =
        HotKV.AI.PromptCache.get_or_call(
          pc,
          %{provider: "openai", model: "gpt-4", messages: [%{role: "user", content: "hi"}]},
          fn -> {:ok, call_llm(...), %{input_tokens: 12, output_tokens: 34, cost_usd: 0.002}} end
        )

  When the `usage` map returned by `fun` also carries `:model`, a
  `HotKV.TokenUsage` built from it is stored with the cache entry (see
  `get_or_call/3`), so a later hit attributes its savings through
  `stats/1`.
  """

  alias HotKV.{AI.PromptCacheKey, Error, LLMStats, PromptCache, TokenUsage}

  defstruct [:conn, :ns, :ttl, :stats_bucket]

  @type t :: %__MODULE__{
          conn: HotKV.conn(),
          ns: String.t(),
          ttl: pos_integer | nil,
          stats_bucket: String.t() | nil
        }

  @doc """
  Builds a `PromptCache` bound to namespace `ns`. `opts`: `:ttl` (seconds,
  default none), `:stats_bucket` (an `HotKV.LLMStats` bucket name to record
  hits/misses/token usage to on every `get_or_call/3`; if omitted, no stats
  are recorded).
  """
  @spec new(HotKV.conn(), String.t(), keyword) :: t
  def new(conn, ns, opts \\ []) do
    %__MODULE__{
      conn: conn,
      ns: ns,
      ttl: Keyword.get(opts, :ttl),
      stats_bucket: Keyword.get(opts, :stats_bucket)
    }
  end

  @doc "Ensures the `PCACHE` namespace backing `pc` exists (`PCACHE.CREATE`, tolerant of it already existing)."
  @spec create_namespace(t, keyword) :: :ok | {:error, Error.t()}
  def create_namespace(%__MODULE__{} = pc, opts \\ []) do
    opts = Keyword.merge([ttl: pc.ttl], opts)

    case PromptCache.create(pc.conn, pc.ns, opts) do
      {:ok, _} -> :ok
      {:error, %Error{message: message}} -> already_exists_ok(message)
    end
  end

  defp already_exists_ok(message) do
    if String.contains?(message, "already exists"), do: :ok, else: {:error, Error.server(message)}
  end

  @doc """
  Returns the cached response for `key_input` (an
  `HotKV.AI.PromptCacheKey.input()`) if present; otherwise calls `fun`,
  caches its response, and returns that. `fun` runs only on a miss and
  must return `{:ok, response, usage}` or `{:error, reason}`. `usage` is a
  map with any of `:input_tokens`, `:output_tokens`, `:cached_tokens`,
  `:cost_usd`, `:latency_ms`, `:error` (all default `0`/`false`; these feed
  `stats_bucket` recording, see `new/3`), `:model`,
  `:cache_write_5m_tokens`, `:cache_write_1h_tokens`. When `:model` is
  also given, a `HotKV.TokenUsage` is built from these same fields
  (`:cached_tokens` becomes its `:cache_read_tokens`) and stored with the
  cache entry, so a later hit attributes it, and its cost once the model
  is priced, through `stats/1`'s `usage_saved_*` counters; it is also
  passed to `HotKV.LLMStats.record/8` so the recorded cost is priced from
  the `LLMSTATS.PRICE` table instead of `:cost_usd`.

  Returns `{:ok, response, hit?}` or `{:error, reason}` (from `fun`, or
  from the cache itself for any error other than `NOLICENSE`).
  """
  @spec get_or_call(t, PromptCacheKey.input(), (... -> {:ok, String.t(), map} | {:error, term})) ::
          {:ok, String.t(), boolean} | {:error, term}
  def get_or_call(%__MODULE__{} = pc, key_input, fun) when is_function(fun, 0) do
    key = PromptCacheKey.build(key_input)

    case PromptCache.get(pc.conn, pc.ns, key) do
      {:ok, nil} -> call_and_cache(pc, key, fun)
      {:ok, response} -> record_and_return(pc, response, true, %{})
      {:error, %Error{kind: :not_licensed}} -> call_without_cache(fun)
      {:error, _} = error -> error
    end
  end

  @doc "`PCACHE.STATS` for this cache's namespace: entries/hits/misses/... plus the `usage_saved_*` savings any `usage` stored with an entry has attributed."
  @spec stats(t) :: {:ok, map} | {:error, Error.t()}
  def stats(%__MODULE__{conn: conn, ns: ns}), do: PromptCache.stats(conn, ns)

  defp call_and_cache(pc, key, fun) do
    case fun.() do
      {:ok, response, usage} ->
        set_opts = [ttl: pc.ttl, usage: token_usage(usage)]
        _ = PromptCache.set(pc.conn, pc.ns, key, response, set_opts)
        record_and_return(pc, response, false, usage)

      {:error, _} = error ->
        error
    end
  end

  defp call_without_cache(fun) do
    case fun.() do
      {:ok, response, _usage} -> {:ok, response, false}
      {:error, _} = error -> error
    end
  end

  defp token_usage(usage) do
    case Map.get(usage, :model) do
      model when is_binary(model) and model != "" ->
        TokenUsage.new(model,
          input_tokens: Map.get(usage, :input_tokens, 0),
          output_tokens: Map.get(usage, :output_tokens, 0),
          cache_read_tokens: Map.get(usage, :cached_tokens, 0),
          cache_write_5m_tokens: Map.get(usage, :cache_write_5m_tokens, 0),
          cache_write_1h_tokens: Map.get(usage, :cache_write_1h_tokens, 0)
        )

      _ ->
        nil
    end
  end

  defp record_and_return(pc, response, hit?, usage) do
    record(pc, hit?, usage)
    {:ok, response, hit?}
  end

  defp record(%__MODULE__{stats_bucket: nil}, _hit?, _usage), do: :ok

  defp record(%__MODULE__{conn: conn, stats_bucket: bucket}, hit?, usage) do
    input = Map.get(usage, :input_tokens, 0)
    output = Map.get(usage, :output_tokens, 0)
    model = Map.get(usage, :model)
    cost = if(model, do: 0, else: Map.get(usage, :cost_usd, 0))
    latency = Map.get(usage, :latency_ms, 0)
    error = Map.get(usage, :error, false)

    {input, output, cached, cost, cw5m, cw1h} =
      if hit? do
        {0, 0, input + output, 0, nil, nil}
      else
        {input, output, Map.get(usage, :cached_tokens, 0), cost,
         Map.get(usage, :cache_write_5m_tokens), Map.get(usage, :cache_write_1h_tokens)}
      end

    record_opts =
      [error: error]
      |> maybe_opt(:model, model)
      |> maybe_opt(:cache_write_5m_tokens, cw5m)
      |> maybe_opt(:cache_write_1h_tokens, cw1h)

    _ = LLMStats.bucket(conn, bucket)
    _ = LLMStats.record(conn, bucket, input, output, cached, cost, latency, record_opts)
    :ok
  end

  defp maybe_opt(opts, _key, nil), do: opts
  defp maybe_opt(opts, key, value), do: Keyword.put(opts, key, value)
end
