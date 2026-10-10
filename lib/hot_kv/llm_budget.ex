# Copyright (c) 2026 HotKV Ltd
# Licensed under the Apache License, Version 2.0. See LICENSE in the project root.

defmodule HotKV.LLMBudget do
  @moduledoc "`LLMBUDGET.*`: token/cost budget enforcement (needs a server license that includes the llm-budget feature)."

  alias HotKV.{Args, Error, Reply, TokenUsage}

  @type conn :: HotKV.conn()

  @doc """
  `LLMBUDGET.SET name token_limit cost_limit_usd window_seconds` ->
  `\"OK\"`, or a server error if the budget-count limit is reached.

  The server reads `cost_limit_usd` as an exact fixed-point amount (digits,
  an optional `.` and at most 6 fractional digits; no exponent, no sign).
  `cost_limit_usd` is therefore formatted by `HotKV.Numeric.format_usd/1`:
  a float is rounded to 6 decimals and printed without an exponent, and a
  string is sent verbatim when it already has that form (use a string to
  pass an exact decimal).
  """
  @spec set(conn, String.t(), non_neg_integer, number | String.t(), pos_integer) ::
          {:ok, String.t()} | {:error, Error.t()}
  def set(conn, name, token_limit, cost_limit_usd, window_seconds) do
    HotKV.command(conn, [
      "LLMBUDGET.SET",
      name,
      token_limit,
      HotKV.Numeric.format_usd(cost_limit_usd),
      window_seconds
    ])
  end

  @doc """
  `LLMBUDGET.CONSUME name tokens cost_usd [usage group]` -> `true` if
  allowed, `false` if it would exceed the cap. `usage` (a
  `HotKV.TokenUsage`) is optional: when given, the server ignores
  `tokens`/`cost_usd` (pass `0` and `0` for them) and instead sums the
  usage's token counts for the total and prices it from the
  `LLMSTATS.PRICE` table instead.
  """
  @spec consume(conn, String.t(), non_neg_integer, number, TokenUsage.t() | nil) ::
          {:ok, boolean} | {:error, Error.t()}
  def consume(conn, name, tokens, cost_usd, usage \\ nil) do
    args = Args.usage(["LLMBUDGET.CONSUME", name, tokens, cost_usd], usage: usage)
    conn |> HotKV.command(args) |> Reply.map(&Reply.to_bool/1)
  end

  @doc """
  `LLMBUDGET.STATUS name` -> `%{tokens_used:, token_limit:, cost_used_usd:,
  cost_limit_usd:, window_seconds:, window_remaining:, requests_allowed:,
  requests_rejected:, unpriced_requests:}`.
  """
  @spec status(conn, String.t()) :: {:ok, map} | {:error, Error.t()}
  def status(conn, name),
    do: conn |> HotKV.command(["LLMBUDGET.STATUS", name]) |> Reply.map(&Reply.to_map/1)

  @doc "`LLMBUDGET.RESET name` -> `true` if the budget existed."
  @spec reset(conn, String.t()) :: {:ok, boolean} | {:error, Error.t()}
  def reset(conn, name),
    do: conn |> HotKV.command(["LLMBUDGET.RESET", name]) |> Reply.map(&Reply.to_bool/1)

  @doc "`LLMBUDGET.DROP name` -> `true` if the budget existed."
  @spec drop(conn, String.t()) :: {:ok, boolean} | {:error, Error.t()}
  def drop(conn, name),
    do: conn |> HotKV.command(["LLMBUDGET.DROP", name]) |> Reply.map(&Reply.to_bool/1)

  @doc "`LLMBUDGET.LIST` -> every budget name."
  @spec list(conn) :: {:ok, [String.t()]} | {:error, Error.t()}
  def list(conn), do: HotKV.command(conn, ["LLMBUDGET.LIST"])
end
