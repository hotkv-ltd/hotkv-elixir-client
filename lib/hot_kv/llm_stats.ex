# Copyright (c) 2026 HotKV Ltd
# Licensed under the Apache License, Version 2.0. See LICENSE in the project root.

defmodule HotKV.LLMStats do
  @moduledoc "`LLMSTATS.*`: LLM usage accounting (needs a server license that includes the llm-stats feature)."

  alias HotKV.{Error, LLMPrice, Reply}

  @type conn :: HotKV.conn()

  @doc "`LLMSTATS.BUCKET name` -> `\"OK\"`. Idempotent create."
  @spec bucket(conn, String.t()) :: {:ok, String.t()} | {:error, Error.t()}
  def bucket(conn, name), do: HotKV.command(conn, ["LLMSTATS.BUCKET", name])

  @doc """
  `LLMSTATS.RECORD bucket input_tokens output_tokens cached_tokens cost_usd
  latency_ms [ERROR 0|1] [MODEL model] [CACHEWRITE5M n] [CACHEWRITE1H n]`
  -> `\"OK\"`. `cached_tokens` is cache-READ tokens.

  `opts`: `:error` (boolean, records the call as failed), `:model` (with
  it, `cost_usd` is ignored by the server, i.e. pass `0`: the cost is
  computed from the `LLMSTATS.PRICE` table instead; an unpriced model
  still records tokens, costs `0` and counts toward
  `unpriced_requests`; for OpenAI, pass `prompt_tokens - cached_tokens`
  as `input_tokens`, since OpenAI reports cache hits as part of
  `prompt_tokens`, unlike Anthropic), `:cache_write_5m_tokens`,
  `:cache_write_1h_tokens` (Anthropic cache-write tokens by TTL tier).
  """
  @spec record(
          conn,
          String.t(),
          non_neg_integer,
          non_neg_integer,
          non_neg_integer,
          number,
          non_neg_integer,
          keyword
        ) ::
          {:ok, String.t()} | {:error, Error.t()}
  def record(
        conn,
        bucket,
        input_tokens,
        output_tokens,
        cached_tokens,
        cost_usd,
        latency_ms,
        opts \\ []
      ) do
    extra =
      []
      |> maybe_error(opts)
      |> add_kv(opts, :model, "MODEL")
      |> add_kv(opts, :cache_write_5m_tokens, "CACHEWRITE5M")
      |> add_kv(opts, :cache_write_1h_tokens, "CACHEWRITE1H")

    HotKV.command(conn, [
      "LLMSTATS.RECORD",
      bucket,
      input_tokens,
      output_tokens,
      cached_tokens,
      cost_usd,
      latency_ms | extra
    ])
  end

  defp maybe_error(acc, opts) do
    if Keyword.get(opts, :error), do: acc ++ ["ERROR", 1], else: acc
  end

  defp add_kv(acc, opts, key, token) do
    case Keyword.get(opts, key) do
      nil -> acc
      value -> acc ++ [token, value]
    end
  end

  @doc """
  `LLMSTATS.GET bucket` -> `%{requests:, errors:, input_tokens:,
  output_tokens:, cached_tokens:, cost_usd:, avg_latency_ms:, requests_1m:,
  tokens_1m:, cost_usd_1m:, cache_write_5m_tokens:, cache_write_1h_tokens:,
  unpriced_requests:}`.
  """
  @spec get(conn, String.t()) :: {:ok, map} | {:error, Error.t()}
  def get(conn, bucket),
    do: conn |> HotKV.command(["LLMSTATS.GET", bucket]) |> Reply.map(&Reply.to_map/1)

  @doc "`LLMSTATS.RESET bucket` -> `true` if the bucket existed."
  @spec reset(conn, String.t()) :: {:ok, boolean} | {:error, Error.t()}
  def reset(conn, bucket),
    do: conn |> HotKV.command(["LLMSTATS.RESET", bucket]) |> Reply.map(&Reply.to_bool/1)

  @doc "`LLMSTATS.DROP bucket` -> `true` if the bucket existed."
  @spec drop(conn, String.t()) :: {:ok, boolean} | {:error, Error.t()}
  def drop(conn, bucket),
    do: conn |> HotKV.command(["LLMSTATS.DROP", bucket]) |> Reply.map(&Reply.to_bool/1)

  @doc "`LLMSTATS.LIST` -> every bucket name."
  @spec list(conn) :: {:ok, [String.t()]} | {:error, Error.t()}
  def list(conn), do: HotKV.command(conn, ["LLMSTATS.LIST"])

  @doc """
  `LLMSTATS.PRICE SET model INPUT usd_per_mtok OUTPUT usd_per_mtok
  [CACHEREAD usd_per_mtok] [CACHEWRITE5M usd_per_mtok] [CACHEWRITE1H
  usd_per_mtok]` -> `\"OK\"`. Sets (or replaces) a custom price override
  for `model`. Prices are USD per 1,000,000 tokens, given as a number or
  an already-formatted decimal string (see `HotKV.LLMPrice.format_price/1`).

  `opts`: `:cache_read_usd_per_mtok`, `:cache_write_5m_usd_per_mtok`,
  `:cache_write_1h_usd_per_mtok` (each defaults, server side, to
  0.1x/1.25x/2x `input_usd_per_mtok` when omitted).
  """
  @spec price_set(conn, String.t(), String.t() | number, String.t() | number, keyword) ::
          {:ok, String.t()} | {:error, Error.t()}
  def price_set(conn, model, input_usd_per_mtok, output_usd_per_mtok, opts \\ []) do
    extra =
      []
      |> add_price(opts, :cache_read_usd_per_mtok, "CACHEREAD")
      |> add_price(opts, :cache_write_5m_usd_per_mtok, "CACHEWRITE5M")
      |> add_price(opts, :cache_write_1h_usd_per_mtok, "CACHEWRITE1H")

    HotKV.command(conn, [
      "LLMSTATS.PRICE",
      "SET",
      model,
      "INPUT",
      LLMPrice.format_price(input_usd_per_mtok),
      "OUTPUT",
      LLMPrice.format_price(output_usd_per_mtok)
      | extra
    ])
  end

  defp add_price(acc, opts, key, token) do
    case Keyword.get(opts, key) do
      nil -> acc
      value -> acc ++ [token, LLMPrice.format_price(value)]
    end
  end

  @doc """
  `LLMSTATS.PRICE GET model` -> `HotKV.LLMPrice.t()`. An unknown model
  comes back with `source` `\"unpriced\"` and every price `0`, not an
  error.
  """
  @spec price_get(conn, String.t()) :: {:ok, LLMPrice.t()} | {:error, Error.t()}
  def price_get(conn, model) do
    conn
    |> HotKV.command(["LLMSTATS.PRICE", "GET", model])
    |> Reply.map(&(&1 |> Reply.to_map() |> LLMPrice.from_fields()))
  end

  @doc "`LLMSTATS.PRICE LIST` -> every known model's `HotKV.LLMPrice.t()` (built in and custom)."
  @spec price_list(conn) :: {:ok, [LLMPrice.t()]} | {:error, Error.t()}
  def price_list(conn) do
    conn
    |> HotKV.command(["LLMSTATS.PRICE", "LIST"])
    |> Reply.map(fn entries ->
      Enum.map(entries, &(&1 |> Reply.to_map() |> LLMPrice.from_fields()))
    end)
  end

  @doc """
  `LLMSTATS.PRICE DEL model` -> `true` if a custom override was removed
  (the model then falls back to its built-in price, if any).
  """
  @spec price_del(conn, String.t()) :: {:ok, boolean} | {:error, Error.t()}
  def price_del(conn, model),
    do: conn |> HotKV.command(["LLMSTATS.PRICE", "DEL", model]) |> Reply.map(&Reply.to_bool/1)
end
