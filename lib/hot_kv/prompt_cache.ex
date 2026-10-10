# Copyright (c) 2026 HotKV Ltd
# Licensed under the Apache License, Version 2.0. See LICENSE in the project root.

defmodule HotKV.PromptCache do
  @moduledoc """
  `PCACHE.*`: the raw prompt/LLM response cache commands
  (needs a server license that includes the prompt-cache feature). For the
  idiomatic get-or-call helper, see `HotKV.AI.PromptCache`.
  """

  alias HotKV.{Args, Error, Reply}

  @type conn :: HotKV.conn()

  @doc """
  `PCACHE.CREATE ns [MAX_ENTRIES n] [TTL seconds] [COST_PER_HIT usd]` ->
  `\"OK\"`.
  """
  @spec create(conn, String.t(), keyword) :: {:ok, String.t()} | {:error, Error.t()}
  def create(conn, ns, opts \\ []) do
    extra =
      []
      |> Args.value(opts, :max_entries, "MAX_ENTRIES")
      |> Args.value(opts, :ttl, "TTL")
      |> Args.value(opts, :cost_per_hit, "COST_PER_HIT")

    HotKV.command(conn, ["PCACHE.CREATE", ns | extra])
  end

  @doc """
  `PCACHE.SET ns prompt response [TTL seconds] [META json] [usage group]`
  -> `\"OK\"`. `opts`: `:ttl`, `:meta`, `:usage` (a `HotKV.TokenUsage`:
  records the original, uncached call's token usage so a later hit
  attributes it, and its cost once the model is priced, to `stats/2`'s
  `usage_saved_*` counters).
  """
  @spec set(conn, String.t(), String.t(), String.t(), keyword) ::
          {:ok, String.t()} | {:error, Error.t()}
  def set(conn, ns, prompt, response, opts \\ []) do
    extra =
      [] |> Args.value(opts, :ttl, "TTL") |> Args.value(opts, :meta, "META") |> Args.usage(opts)

    HotKV.command(conn, ["PCACHE.SET", ns, prompt, response | extra])
  end

  @doc "`PCACHE.GET ns prompt` -> the cached response, `nil` on a miss."
  @spec get(conn, String.t(), String.t()) :: {:ok, String.t() | nil} | {:error, Error.t()}
  def get(conn, ns, prompt), do: HotKV.command(conn, ["PCACHE.GET", ns, prompt])

  @doc "`PCACHE.GETEX ns prompt` -> `%{response:, metadata:, hit_count:}`, `nil` on a miss."
  @spec getex(conn, String.t(), String.t()) :: {:ok, map | nil} | {:error, Error.t()}
  def getex(conn, ns, prompt) do
    conn
    |> HotKV.command(["PCACHE.GETEX", ns, prompt])
    |> Reply.map(fn
      nil ->
        nil

      [response, metadata, hit_count] ->
        %{response: response, metadata: metadata, hit_count: hit_count}
    end)
  end

  @doc "`PCACHE.DEL ns prompt` -> `true` if an entry was removed."
  @spec del(conn, String.t(), String.t()) :: {:ok, boolean} | {:error, Error.t()}
  def del(conn, ns, prompt),
    do: conn |> HotKV.command(["PCACHE.DEL", ns, prompt]) |> Reply.map(&Reply.to_bool/1)

  @doc """
  `PCACHE.STATS ns` -> `%{entries:, hits:, misses:, evictions:,
  memory_bytes:, hit_rate:, p50_ns:, p95_ns:, p99_ns:, cost_saved_usd:,
  usage_saved_requests:, usage_saved_input_tokens:,
  usage_saved_output_tokens:, usage_saved_cache_read_tokens:,
  usage_saved_cache_write_tokens:, usage_saved_cost_usd:}`.
  """
  @spec stats(conn, String.t()) :: {:ok, map} | {:error, Error.t()}
  def stats(conn, ns),
    do: conn |> HotKV.command(["PCACHE.STATS", ns]) |> Reply.map(&Reply.to_map/1)

  @doc "`PCACHE.FLUSH ns` -> the number of entries flushed."
  @spec flush(conn, String.t()) :: {:ok, integer} | {:error, Error.t()}
  def flush(conn, ns), do: HotKV.command(conn, ["PCACHE.FLUSH", ns])

  @doc "`PCACHE.DROP ns` -> `true` if the namespace existed."
  @spec drop(conn, String.t()) :: {:ok, boolean} | {:error, Error.t()}
  def drop(conn, ns),
    do: conn |> HotKV.command(["PCACHE.DROP", ns]) |> Reply.map(&Reply.to_bool/1)

  @doc "`PCACHE.LIST` -> every namespace name."
  @spec list(conn) :: {:ok, [String.t()]} | {:error, Error.t()}
  def list(conn), do: HotKV.command(conn, ["PCACHE.LIST"])

  @doc "`PCACHE.CONFIG ns SET MAX_ENTRIES|TTL|COST_PER_HIT value` -> `\"OK\"`."
  @spec config_set(conn, String.t(), :max_entries | :ttl | :cost_per_hit, term) ::
          {:ok, String.t()} | {:error, Error.t()}
  def config_set(conn, ns, param, value) when param in [:max_entries, :ttl, :cost_per_hit] do
    HotKV.command(conn, [
      "PCACHE.CONFIG",
      ns,
      "SET",
      param |> Atom.to_string() |> String.upcase(),
      value
    ])
  end
end
