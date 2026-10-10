# Copyright (c) 2026 HotKV Ltd
# Licensed under the Apache License, Version 2.0. See LICENSE in the project root.

defmodule HotKV.SemanticCache do
  @moduledoc """
  `SCACHE.*`: the raw semantic cache commands (needs a server license that includes
  the semantic-cache feature). For the idiomatic get-or-call helper, see
  `HotKV.AI.SemanticCache`.
  """

  alias HotKV.{Args, Error, Reply}

  @type conn :: HotKV.conn()
  @type vector :: [float | integer]

  @doc """
  `SCACHE.CREATE ns dims [METRIC cosine|l2|ip] [THRESHOLD 0.0-1.0] [TTL seconds]`
  -> `\"OK\"`. `opts`: `:metric` (default `:cosine`), `:threshold` (default
  `0.85`), `:ttl` (default `0`, no expiry).
  """
  @spec create(conn, String.t(), pos_integer, keyword) :: {:ok, String.t()} | {:error, Error.t()}
  def create(conn, ns, dims, opts \\ []) do
    extra =
      []
      |> add_metric(opts)
      |> Args.value(opts, :threshold, "THRESHOLD")
      |> Args.value(opts, :ttl, "TTL")

    HotKV.command(conn, ["SCACHE.CREATE", ns, dims | extra])
  end

  defp add_metric(acc, opts) do
    case Keyword.get(opts, :metric) do
      nil -> acc
      metric when metric in [:cosine, :l2, :ip] -> acc ++ ["METRIC", Atom.to_string(metric)]
    end
  end

  @doc """
  `SCACHE.SET ns query_text response val1 ... valN [TTL seconds] [usage
  group]` -> `\"OK\"`. `opts`: `:ttl`, `:usage` (a `HotKV.TokenUsage`:
  records the original, uncached call's token usage so a later hit
  attributes it, and its cost once the model is priced, to `stats/2`'s
  `usage_saved_*` counters).
  """
  @spec set(conn, String.t(), String.t(), String.t(), vector, keyword) ::
          {:ok, String.t()} | {:error, Error.t()}
  def set(conn, ns, query_text, response, vector, opts \\ []) do
    extra = [] |> Args.value(opts, :ttl, "TTL") |> Args.usage(opts)
    HotKV.command(conn, ["SCACHE.SET", ns, query_text, response | vector_args(vector)] ++ extra)
  end

  @doc """
  `SCACHE.GET ns val1 ... valN [THRESHOLD override]` -> `{response,
  similarity}` on a hit above threshold, else `nil`.
  """
  @spec get(conn, String.t(), vector, float | nil) ::
          {:ok, {String.t(), float} | nil} | {:error, Error.t()}
  def get(conn, ns, vector, threshold_override \\ nil) do
    extra = if threshold_override, do: ["THRESHOLD", threshold_override], else: []

    conn
    |> HotKV.command(["SCACHE.GET", ns | vector_args(vector)] ++ extra)
    |> Reply.map(fn
      nil -> nil
      [response, similarity] -> {response, Reply.to_double(similarity)}
    end)
  end

  @doc """
  `SCACHE.STATS ns` -> `%{entries:, hits:, misses:, hit_rate:, p50_us:,
  usage_saved_requests:, usage_saved_input_tokens:,
  usage_saved_output_tokens:, usage_saved_cache_read_tokens:,
  usage_saved_cache_write_tokens:, usage_saved_cost_usd:}`.
  """
  @spec stats(conn, String.t()) :: {:ok, map} | {:error, Error.t()}
  def stats(conn, ns),
    do: conn |> HotKV.command(["SCACHE.STATS", ns]) |> Reply.map(&Reply.to_map/1)

  @doc "`SCACHE.FLUSH ns` -> `true` if the namespace existed."
  @spec flush(conn, String.t()) :: {:ok, boolean} | {:error, Error.t()}
  def flush(conn, ns),
    do: conn |> HotKV.command(["SCACHE.FLUSH", ns]) |> Reply.map(&Reply.to_bool/1)

  @doc "`SCACHE.DROP ns` -> `true` if the namespace existed."
  @spec drop(conn, String.t()) :: {:ok, boolean} | {:error, Error.t()}
  def drop(conn, ns),
    do: conn |> HotKV.command(["SCACHE.DROP", ns]) |> Reply.map(&Reply.to_bool/1)

  @doc "`SCACHE.LIST` -> every namespace name."
  @spec list(conn) :: {:ok, [String.t()]} | {:error, Error.t()}
  def list(conn), do: HotKV.command(conn, ["SCACHE.LIST"])

  @doc "`SCACHE.THRESHOLD ns value` -> `\"OK\"`. `value` in `0.0..1.0`."
  @spec threshold(conn, String.t(), float) :: {:ok, String.t()} | {:error, Error.t()}
  def threshold(conn, ns, value), do: HotKV.command(conn, ["SCACHE.THRESHOLD", ns, to_arg(value)])

  defp vector_args(vector), do: Enum.map(vector, &to_arg/1)
  defp to_arg(value) when is_float(value), do: HotKV.Numeric.format_float(value)
  defp to_arg(value), do: value
end
