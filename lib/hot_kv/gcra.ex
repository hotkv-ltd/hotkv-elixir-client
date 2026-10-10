# Copyright (c) 2026 HotKV Ltd
# Licensed under the Apache License, Version 2.0. See LICENSE in the project root.

defmodule HotKV.Gcra do
  @moduledoc """
  `GCRA.*`: the generic cell rate algorithm rate limiter primitive
  (distinct from `RATELIMIT.*`, see `HotKV.RateLimit`). Core, no license
  required.
  """

  alias HotKV.Error

  @type conn :: HotKV.conn()

  @doc """
  `GCRA.LIMIT key period_ms burst [count]` -> `%{denied:, limit:,
  remaining:, retry_after_ms:, reset_after_ms:}`. `denied` is `false` when
  the request is allowed. `count` (tokens to consume) defaults to `1`.
  """
  @spec limit(conn, String.t(), pos_integer, pos_integer, pos_integer) ::
          {:ok,
           %{
             denied: boolean,
             limit: integer,
             remaining: integer,
             retry_after_ms: integer,
             reset_after_ms: integer
           }}
          | {:error, Error.t()}
  def limit(conn, key, period_ms, burst, count \\ 1) do
    conn
    |> HotKV.command(["GCRA.LIMIT", key, period_ms, burst, count])
    |> HotKV.Reply.map(fn [denied, limit_val, remaining, retry_after_ms, reset_after_ms] ->
      %{
        denied: denied == 1,
        limit: limit_val,
        remaining: remaining,
        retry_after_ms: retry_after_ms,
        reset_after_ms: reset_after_ms
      }
    end)
  end

  @doc "`GCRA.RESET key [key ...]` -> the number of keys that had state and were reset."
  @spec reset(conn, String.t() | [String.t()]) :: {:ok, integer} | {:error, Error.t()}
  def reset(conn, keys), do: HotKV.command(conn, ["GCRA.RESET" | List.wrap(keys)])
end
