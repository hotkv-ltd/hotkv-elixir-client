# Copyright (c) 2026 HotKV Ltd
# Licensed under the Apache License, Version 2.0. See LICENSE in the project root.

defmodule HotKV.AI.SemanticCache do
  @moduledoc """
  An idiomatic get-or-call cache in front of `SCACHE.*` (`HotKV.SemanticCache`):
  looks up the nearest cached answer to a caller-supplied embedding vector
  above the namespace's similarity threshold, calling the caller's function
  only on a miss. This never computes embeddings itself, so it has no
  dependency on any particular embedding provider; pass a vector from
  whichever provider's client you already use.

  Needs a server license that includes the semantic-cache feature; if
  unavailable (`NOLICENSE`), `get_or_call/4` treats it as a cache miss and
  calls through.

      sc = HotKV.AI.SemanticCache.new(conn, "faq_cache", ttl: 86_400)
      :ok = HotKV.AI.SemanticCache.create_namespace(sc, 1536)

      {:ok, answer, hit?} =
        HotKV.AI.SemanticCache.get_or_call(sc, question, embed(question), fn ->
          {:ok, call_llm(question)}
        end)

  `fun` may also return `{:ok, response, usage}`, `usage` a map with
  `:model` and any of `:input_tokens`, `:output_tokens`, `:cached_tokens`,
  `:cache_write_5m_tokens`, `:cache_write_1h_tokens`: with `:model`, a
  `HotKV.TokenUsage` is stored with the cache entry, so a later hit
  attributes its savings through `stats/1`.
  """

  alias HotKV.{Error, SemanticCache, TokenUsage}

  defstruct [:conn, :ns, :ttl]

  @type t :: %__MODULE__{conn: HotKV.conn(), ns: String.t(), ttl: pos_integer | nil}
  @type vector :: [float | integer]

  @doc "Builds a `SemanticCache` bound to namespace `ns`. `opts`: `:ttl` (seconds, default none)."
  @spec new(HotKV.conn(), String.t(), keyword) :: t
  def new(conn, ns, opts \\ []), do: %__MODULE__{conn: conn, ns: ns, ttl: Keyword.get(opts, :ttl)}

  @doc """
  Ensures the `SCACHE` namespace backing `sc` exists (`SCACHE.CREATE`,
  tolerant of it already existing), with the given embedding `dims` and
  `opts`: `:metric` (default `:cosine`), `:threshold` (default `0.85`).
  """
  @spec create_namespace(t, pos_integer, keyword) :: :ok | {:error, Error.t()}
  def create_namespace(%__MODULE__{} = sc, dims, opts \\ []) do
    opts = Keyword.merge([ttl: sc.ttl], opts)

    case SemanticCache.create(sc.conn, sc.ns, dims, opts) do
      {:ok, _} -> :ok
      {:error, %Error{message: message}} -> already_exists_ok(message)
    end
  end

  defp already_exists_ok(message) do
    if String.contains?(message, "already exists"), do: :ok, else: {:error, Error.server(message)}
  end

  @doc """
  Returns the cached answer for the nearest neighbor of `vector` above the
  namespace's similarity threshold, if any; otherwise calls `fun` (which
  must return `{:ok, response}`, `{:ok, response, usage}` (see the
  moduledoc) or `{:error, reason}`), caches `{query, response, vector}`
  (with `usage`, when given and carrying `:model`), and returns the fresh
  answer.

  Returns `{:ok, response, hit?}` or `{:error, reason}`.
  """
  @spec get_or_call(
          t,
          String.t(),
          vector,
          (... -> {:ok, String.t()} | {:ok, String.t(), map} | {:error, term})
        ) :: {:ok, String.t(), boolean} | {:error, term}
  def get_or_call(%__MODULE__{} = sc, query_text, vector, fun) when is_function(fun, 0) do
    case SemanticCache.get(sc.conn, sc.ns, vector) do
      {:ok, {response, _similarity}} -> {:ok, response, true}
      {:ok, nil} -> call_and_cache(sc, query_text, vector, fun)
      {:error, %Error{kind: :not_licensed}} -> call_without_cache(fun)
      {:error, _} = error -> error
    end
  end

  @doc "`SCACHE.STATS` for this cache's namespace: entries/hits/misses/hit_rate/p50_us plus the `usage_saved_*` savings any `usage` stored with an entry has attributed."
  @spec stats(t) :: {:ok, map} | {:error, Error.t()}
  def stats(%__MODULE__{conn: conn, ns: ns}), do: SemanticCache.stats(conn, ns)

  defp call_and_cache(sc, query_text, vector, fun) do
    case fun.() do
      {:ok, response} ->
        _ = SemanticCache.set(sc.conn, sc.ns, query_text, response, vector, ttl: sc.ttl)
        {:ok, response, false}

      {:ok, response, usage} ->
        opts = [ttl: sc.ttl, usage: token_usage(usage)]
        _ = SemanticCache.set(sc.conn, sc.ns, query_text, response, vector, opts)
        {:ok, response, false}

      {:error, _} = error ->
        error
    end
  end

  defp call_without_cache(fun) do
    case fun.() do
      {:ok, response} -> {:ok, response, false}
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
end
