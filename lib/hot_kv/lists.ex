# Copyright (c) 2026 HotKV Ltd
# Licensed under the Apache License, Version 2.0. See LICENSE in the project root.

defmodule HotKV.Lists do
  @moduledoc "List commands."

  alias HotKV.{Args, Error}

  @type conn :: HotKV.conn()
  @type key :: String.t()

  @doc "`RPUSH key value [value ...]` -> the list length after the push."
  @spec rpush(conn, key, binary | [binary]) :: {:ok, integer} | {:error, Error.t()}
  def rpush(conn, key, values), do: HotKV.command(conn, ["RPUSH", key | Args.wrap(values)])

  @doc "`LPUSH key value [value ...]` -> the list length after the push."
  @spec lpush(conn, key, binary | [binary]) :: {:ok, integer} | {:error, Error.t()}
  def lpush(conn, key, values), do: HotKV.command(conn, ["LPUSH", key | Args.wrap(values)])

  @doc "`RPUSHX key value [value ...]` -> the list length after the push, `0` if `key` does not exist."
  @spec rpushx(conn, key, binary | [binary]) :: {:ok, integer} | {:error, Error.t()}
  def rpushx(conn, key, values), do: HotKV.command(conn, ["RPUSHX", key | Args.wrap(values)])

  @doc "`LPUSHX key value [value ...]` -> the list length after the push, `0` if `key` does not exist."
  @spec lpushx(conn, key, binary | [binary]) :: {:ok, integer} | {:error, Error.t()}
  def lpushx(conn, key, values), do: HotKV.command(conn, ["LPUSHX", key | Args.wrap(values)])

  @doc "`LPOP key [count]` -> the popped value (or list of values with `count`), `nil` if empty/missing."
  @spec lpop(conn, key, non_neg_integer | nil) ::
          {:ok, binary | [binary] | nil} | {:error, Error.t()}
  def lpop(conn, key, count \\ nil), do: HotKV.command(conn, ["LPOP", key | count_arg(count)])

  @doc "`RPOP key [count]` -> the popped value (or list of values with `count`), `nil` if empty/missing."
  @spec rpop(conn, key, non_neg_integer | nil) ::
          {:ok, binary | [binary] | nil} | {:error, Error.t()}
  def rpop(conn, key, count \\ nil), do: HotKV.command(conn, ["RPOP", key | count_arg(count)])

  defp count_arg(nil), do: []
  defp count_arg(count), do: [count]

  @doc "`LLEN key` -> the list length, `0` if `key` does not exist."
  @spec llen(conn, key) :: {:ok, integer} | {:error, Error.t()}
  def llen(conn, key), do: HotKV.command(conn, ["LLEN", key])

  @doc "`LRANGE key start stop` -> the elements in that (inclusive, possibly negative) range."
  @spec lrange(conn, key, integer, integer) :: {:ok, [binary]} | {:error, Error.t()}
  def lrange(conn, key, start_index, stop_index),
    do: HotKV.command(conn, ["LRANGE", key, start_index, stop_index])

  @doc "`LINDEX key index` -> the element at `index`, `nil` if out of range."
  @spec lindex(conn, key, integer) :: {:ok, binary | nil} | {:error, Error.t()}
  def lindex(conn, key, index), do: HotKV.command(conn, ["LINDEX", key, index])

  @doc "`LSET key index value` -> `\"OK\"`."
  @spec lset(conn, key, integer, binary) :: {:ok, String.t()} | {:error, Error.t()}
  def lset(conn, key, index, value), do: HotKV.command(conn, ["LSET", key, index, value])

  @doc "`LINSERT key BEFORE|AFTER pivot element` -> the list length after inserting, `-1` if `pivot` was not found."
  @spec linsert(conn, key, :before | :after, binary, binary) ::
          {:ok, integer} | {:error, Error.t()}
  def linsert(conn, key, where, pivot, element) when where in [:before, :after] do
    HotKV.command(conn, [
      "LINSERT",
      key,
      where |> Atom.to_string() |> String.upcase(),
      pivot,
      element
    ])
  end

  @doc "`LREM key count element` -> the number of removed elements."
  @spec lrem(conn, key, integer, binary) :: {:ok, integer} | {:error, Error.t()}
  def lrem(conn, key, count, element), do: HotKV.command(conn, ["LREM", key, count, element])

  @doc "`LTRIM key start stop` -> `\"OK\"`."
  @spec ltrim(conn, key, integer, integer) :: {:ok, String.t()} | {:error, Error.t()}
  def ltrim(conn, key, start_index, stop_index),
    do: HotKV.command(conn, ["LTRIM", key, start_index, stop_index])

  @doc "`RPOPLPUSH source destination` -> the moved element, `nil` if `source` is empty."
  @spec rpoplpush(conn, key, key) :: {:ok, binary | nil} | {:error, Error.t()}
  def rpoplpush(conn, source, destination),
    do: HotKV.command(conn, ["RPOPLPUSH", source, destination])

  @doc "`LMOVE source destination LEFT|RIGHT LEFT|RIGHT` -> the moved element, `nil` if `source` is empty."
  @spec lmove(conn, key, key, :left | :right, :left | :right) ::
          {:ok, binary | nil} | {:error, Error.t()}
  def lmove(conn, source, destination, from_side, to_side) do
    HotKV.command(conn, ["LMOVE", source, destination, side(from_side), side(to_side)])
  end

  defp side(:left), do: "LEFT"
  defp side(:right), do: "RIGHT"

  @doc """
  `LPOS key element [opts]` -> the matching index (or list of indices with
  `opts[:count]`), `nil` if not found. `opts`: `:rank`, `:count`, `:maxlen`.
  """
  @spec lpos(conn, key, binary, keyword) :: {:ok, integer | [integer] | nil} | {:error, Error.t()}
  def lpos(conn, key, element, opts \\ []) do
    extra =
      []
      |> Args.value(opts, :rank, "RANK")
      |> Args.value(opts, :count, "COUNT")
      |> Args.value(opts, :maxlen, "MAXLEN")

    HotKV.command(conn, ["LPOS", key, element | extra])
  end

  @doc "`BLPOP key [key ...] timeout` -> `[key, value]`, `nil` on timeout."
  @spec blpop(conn, key | [key], number) :: {:ok, [binary] | nil} | {:error, Error.t()}
  def blpop(conn, keys, timeout),
    do:
      HotKV.command(conn, ["BLPOP" | Args.wrap(keys) ++ [timeout_arg(timeout)]],
        timeout: blocking_timeout(timeout)
      )

  @doc "`BRPOP key [key ...] timeout` -> `[key, value]`, `nil` on timeout."
  @spec brpop(conn, key | [key], number) :: {:ok, [binary] | nil} | {:error, Error.t()}
  def brpop(conn, keys, timeout),
    do:
      HotKV.command(conn, ["BRPOP" | Args.wrap(keys) ++ [timeout_arg(timeout)]],
        timeout: blocking_timeout(timeout)
      )

  @doc "`BLMOVE source destination LEFT|RIGHT LEFT|RIGHT timeout` -> the moved element, `nil` on timeout."
  @spec blmove(conn, key, key, :left | :right, :left | :right, number) ::
          {:ok, binary | nil} | {:error, Error.t()}
  def blmove(conn, source, destination, from_side, to_side, timeout) do
    HotKV.command(
      conn,
      ["BLMOVE", source, destination, side(from_side), side(to_side), timeout_arg(timeout)],
      timeout: blocking_timeout(timeout)
    )
  end

  defp timeout_arg(seconds) when is_float(seconds), do: HotKV.Numeric.format_float(seconds)
  defp timeout_arg(seconds), do: seconds

  # The command's own BLPOP-style timeout is in seconds and 0 means "block
  # forever"; give the client call itself a little headroom over that, or a
  # generous default when the command may block indefinitely.
  @doc false
  def blocking_timeout(seconds) when seconds == 0, do: :infinity
  def blocking_timeout(seconds), do: round(seconds * 1000) + 5_000
end
