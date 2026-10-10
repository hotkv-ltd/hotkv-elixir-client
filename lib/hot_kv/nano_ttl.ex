# Copyright (c) 2026 HotKV Ltd
# Licensed under the Apache License, Version 2.0. See LICENSE in the project root.

defmodule HotKV.NanoTTL do
  @moduledoc "`NEXPIRE`/`NTTL`/`NEXPIREAT`: nanosecond-resolution key TTLs. Core, no license required."

  alias HotKV.{Error, Reply}

  @type conn :: HotKV.conn()

  @doc "`NEXPIRE key nanoseconds` -> `true` if the TTL was set. `nanoseconds` is relative to now."
  @spec nexpire(conn, String.t(), integer) :: {:ok, boolean} | {:error, Error.t()}
  def nexpire(conn, key, nanoseconds),
    do: conn |> HotKV.command(["NEXPIRE", key, nanoseconds]) |> Reply.map(&Reply.to_bool/1)

  @doc "`NTTL key` -> remaining TTL in nanoseconds, `-2` if `key` does not exist, `-1` if it has no expiry."
  @spec nttl(conn, String.t()) :: {:ok, integer} | {:error, Error.t()}
  def nttl(conn, key), do: HotKV.command(conn, ["NTTL", key])

  @doc "`NEXPIREAT key nanosecond_unix_timestamp` -> `true` if the TTL was set."
  @spec nexpireat(conn, String.t(), integer) :: {:ok, boolean} | {:error, Error.t()}
  def nexpireat(conn, key, nanosecond_unix_timestamp) do
    conn
    |> HotKV.command(["NEXPIREAT", key, nanosecond_unix_timestamp])
    |> Reply.map(&Reply.to_bool/1)
  end
end
