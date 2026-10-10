# Copyright (c) 2026 HotKV Ltd
# Licensed under the Apache License, Version 2.0. See LICENSE in the project root.

defmodule HotKV.RateLimit do
  @moduledoc "`RATELIMIT.*`: named rate limiters (needs a server license that includes the rate-limiting feature)."

  alias HotKV.{Args, Error, Reply}

  @type conn :: HotKV.conn()

  @doc """
  `RATELIMIT.CREATE name limit window_ms [ALGO sliding_window|token_bucket|leaky_bucket] [REFILL rate] [DRAIN rate]`
  -> `\"OK\"`. `opts`: `:algo` (default `:sliding_window`), `:refill`,
  `:drain` (required, `> 0`, for the matching bucket algorithm).
  """
  @spec create(conn, String.t(), pos_integer, pos_integer, keyword) ::
          {:ok, String.t()} | {:error, Error.t()}
  def create(conn, name, limit, window_ms, opts \\ []) do
    extra =
      []
      |> add_algo(opts)
      |> Args.value(opts, :refill, "REFILL")
      |> Args.value(opts, :drain, "DRAIN")

    HotKV.command(conn, ["RATELIMIT.CREATE", name, limit, window_ms | extra])
  end

  defp add_algo(acc, opts) do
    case Keyword.get(opts, :algo) do
      nil ->
        acc

      algo when algo in [:sliding_window, :token_bucket, :leaky_bucket] ->
        acc ++ ["ALGO", Atom.to_string(algo)]
    end
  end

  @doc """
  `RATELIMIT.CHECK name key [COST n]` -> `%{allowed:, remaining:,
  retry_after_ms:, limit:, current:}`. Mutating: advances limiter state.
  `opts[:cost]` (tokens consumed) defaults to `1`.
  """
  @spec check(conn, String.t(), String.t(), keyword) :: {:ok, map} | {:error, Error.t()}
  def check(conn, name, key, opts \\ []) do
    extra = Args.value([], opts, :cost, "COST")
    conn |> HotKV.command(["RATELIMIT.CHECK", name, key | extra]) |> Reply.map(&result/1)
  end

  @doc "`RATELIMIT.PEEK name key` -> same shape as `check/4`, without consuming."
  @spec peek(conn, String.t(), String.t()) :: {:ok, map} | {:error, Error.t()}
  def peek(conn, name, key),
    do: conn |> HotKV.command(["RATELIMIT.PEEK", name, key]) |> Reply.map(&result/1)

  defp result([allowed, remaining, retry_after_ms, limit, current]) do
    %{
      allowed: allowed == 1,
      remaining: remaining,
      retry_after_ms: retry_after_ms,
      limit: limit,
      current: current
    }
  end

  @doc "`RATELIMIT.RESET name key` -> `\"OK\"`, or a server error if the limiter does not exist."
  @spec reset(conn, String.t(), String.t()) :: {:ok, String.t()} | {:error, Error.t()}
  def reset(conn, name, key), do: HotKV.command(conn, ["RATELIMIT.RESET", name, key])

  @doc "`RATELIMIT.STATS name` -> `%{name:, algo:, limit:, window_ms:, unique_keys:, total_allowed:, total_denied:}`."
  @spec stats(conn, String.t()) :: {:ok, map} | {:error, Error.t()}
  def stats(conn, name),
    do: conn |> HotKV.command(["RATELIMIT.STATS", name]) |> Reply.map(&Reply.to_map/1)

  @doc "`RATELIMIT.DROP name` -> `\"OK\"`, or a server error if the limiter does not exist."
  @spec drop(conn, String.t()) :: {:ok, String.t()} | {:error, Error.t()}
  def drop(conn, name), do: HotKV.command(conn, ["RATELIMIT.DROP", name])

  @doc "`RATELIMIT.LIST` -> every limiter name."
  @spec list(conn) :: {:ok, [String.t()]} | {:error, Error.t()}
  def list(conn), do: HotKV.command(conn, ["RATELIMIT.LIST"])
end
