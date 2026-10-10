# Copyright (c) 2026 HotKV Ltd
# Licensed under the Apache License, Version 2.0. See LICENSE in the project root.

defmodule HotKV.Strings do
  @moduledoc "String commands: `GET`/`SET` and friends."

  alias HotKV.{Args, Error, Reply}

  @type conn :: HotKV.conn()
  @type key :: String.t()

  @doc "`GET key` -> the value, or `nil` if `key` does not exist."
  @spec get(conn, key) :: {:ok, binary | nil} | {:error, Error.t()}
  def get(conn, key), do: HotKV.command(conn, ["GET", key])

  @doc """
  `SET key value [opts]` -> `"OK"`, the old value (with `opts[:get]`), or
  `nil` if a condition (`NX`/`XX`) was not met.

  `opts`: `:nx`, `:xx`, `:keepttl`, `:get` (booleans), `:ex`, `:px`,
  `:exat`, `:pxat` (integers, mutually exclusive expiry forms), and the
  HotKV compare-and-set conditions `:ifeq`, `:ifne` (compare the current
  string with a value) and `:ifdeq`, `:ifdne` (compare its 16 hex digit
  digest, see `digest/2`).
  """
  @spec set(conn, key, binary, keyword) :: {:ok, binary | nil} | {:error, Error.t()}
  def set(conn, key, value, opts \\ []) do
    extra =
      []
      |> Args.flag(opts, :nx, "NX")
      |> Args.flag(opts, :xx, "XX")
      |> Args.value(opts, :ifeq, "IFEQ")
      |> Args.value(opts, :ifne, "IFNE")
      |> Args.value(opts, :ifdeq, "IFDEQ")
      |> Args.value(opts, :ifdne, "IFDNE")
      |> Args.value(opts, :ex, "EX")
      |> Args.value(opts, :px, "PX")
      |> Args.value(opts, :exat, "EXAT")
      |> Args.value(opts, :pxat, "PXAT")
      |> Args.flag(opts, :keepttl, "KEEPTTL")
      |> Args.flag(opts, :get, "GET")

    HotKV.command(conn, ["SET", key, value | extra])
  end

  @doc """
  `DIGEST key` -> the XXH3-64 digest of the string as 16 hex digits, `nil`
  if `key` does not exist. Compare it with the `:ifdeq` / `:ifdne` options
  of `set/4` and `delex/3`.
  """
  @spec digest(conn, key) :: {:ok, String.t() | nil} | {:error, Error.t()}
  def digest(conn, key), do: HotKV.command(conn, ["DIGEST", key])

  @doc """
  `DELEX key [IFEQ value | IFNE value | IFDEQ digest | IFDNE digest]` ->
  `true` if the key was deleted, `false` if it did not exist or the
  condition was not met. `opts`: one of `:ifeq`, `:ifne`, `:ifdeq`,
  `:ifdne`.
  """
  @spec delex(conn, key, keyword) :: {:ok, boolean} | {:error, Error.t()}
  def delex(conn, key, opts \\ []) do
    extra =
      []
      |> Args.value(opts, :ifeq, "IFEQ")
      |> Args.value(opts, :ifne, "IFNE")
      |> Args.value(opts, :ifdeq, "IFDEQ")
      |> Args.value(opts, :ifdne, "IFDNE")

    conn |> HotKV.command(["DELEX", key | extra]) |> Reply.map(&Reply.to_bool/1)
  end

  @doc """
  `MSETEX numkeys key value [key value ...] [NX|XX] [EX|PX|EXAT|PXAT n|KEEPTTL]`
  -> `true` if the keys were set, `false` when `:nx` / `:xx` failed. All
  keys share one expiry. `pairs` is `[{key, value}, ...]` or a flat list.
  `opts`: `:nx`, `:xx`, `:keepttl` (booleans), `:ex`, `:px`, `:exat`,
  `:pxat` (integers).
  """
  @spec msetex(conn, [{key, binary}] | [binary], keyword) ::
          {:ok, boolean} | {:error, Error.t()}
  def msetex(conn, pairs, opts \\ []) do
    flat = flatten_pairs(pairs)

    extra =
      []
      |> Args.flag(opts, :nx, "NX")
      |> Args.flag(opts, :xx, "XX")
      |> Args.value(opts, :ex, "EX")
      |> Args.value(opts, :px, "PX")
      |> Args.value(opts, :exat, "EXAT")
      |> Args.value(opts, :pxat, "PXAT")
      |> Args.flag(opts, :keepttl, "KEEPTTL")

    conn
    |> HotKV.command(["MSETEX", div(length(flat), 2) | flat] ++ extra)
    |> Reply.map(&Reply.to_bool/1)
  end

  @doc "`SETNX key value` -> `true` if `key` was set (it did not exist)."
  @spec setnx(conn, key, binary) :: {:ok, boolean} | {:error, Error.t()}
  def setnx(conn, key, value),
    do: conn |> HotKV.command(["SETNX", key, value]) |> Reply.map(&Reply.to_bool/1)

  @doc "`SETEX key seconds value` -> `\"OK\"`."
  @spec setex(conn, key, pos_integer, binary) :: {:ok, String.t()} | {:error, Error.t()}
  def setex(conn, key, seconds, value), do: HotKV.command(conn, ["SETEX", key, seconds, value])

  @doc "`PSETEX key milliseconds value` -> `\"OK\"`."
  @spec psetex(conn, key, pos_integer, binary) :: {:ok, String.t()} | {:error, Error.t()}
  def psetex(conn, key, milliseconds, value),
    do: HotKV.command(conn, ["PSETEX", key, milliseconds, value])

  @doc "`GETSET key value` -> the old value, or `nil`."
  @spec getset(conn, key, binary) :: {:ok, binary | nil} | {:error, Error.t()}
  def getset(conn, key, value), do: HotKV.command(conn, ["GETSET", key, value])

  @doc "`GETDEL key` -> the value, deleting `key`; `nil` if it did not exist."
  @spec getdel(conn, key) :: {:ok, binary | nil} | {:error, Error.t()}
  def getdel(conn, key), do: HotKV.command(conn, ["GETDEL", key])

  @doc """
  `GETEX key [opts]` -> the value, optionally changing its TTL.
  `opts`: `:ex`, `:px`, `:exat`, `:pxat` (integers), `:persist` (boolean).
  """
  @spec getex(conn, key, keyword) :: {:ok, binary | nil} | {:error, Error.t()}
  def getex(conn, key, opts \\ []) do
    extra =
      []
      |> Args.value(opts, :ex, "EX")
      |> Args.value(opts, :px, "PX")
      |> Args.value(opts, :exat, "EXAT")
      |> Args.value(opts, :pxat, "PXAT")
      |> Args.flag(opts, :persist, "PERSIST")

    HotKV.command(conn, ["GETEX", key | extra])
  end

  @doc "`APPEND key value` -> the length of the string after appending."
  @spec append(conn, key, binary) :: {:ok, integer} | {:error, Error.t()}
  def append(conn, key, value), do: HotKV.command(conn, ["APPEND", key, value])

  @doc "`STRLEN key` -> the length of the value, `0` if `key` does not exist."
  @spec strlen(conn, key) :: {:ok, integer} | {:error, Error.t()}
  def strlen(conn, key), do: HotKV.command(conn, ["STRLEN", key])

  @doc "`INCR key` -> the value after incrementing."
  @spec incr(conn, key) :: {:ok, integer} | {:error, Error.t()}
  def incr(conn, key), do: HotKV.command(conn, ["INCR", key])

  @doc "`INCRBY key increment` -> the value after incrementing."
  @spec incrby(conn, key, integer) :: {:ok, integer} | {:error, Error.t()}
  def incrby(conn, key, increment), do: HotKV.command(conn, ["INCRBY", key, increment])

  @doc "`INCRBYFLOAT key increment` -> the value after incrementing, as a string."
  @spec incrbyfloat(conn, key, float | String.t()) :: {:ok, binary} | {:error, Error.t()}
  def incrbyfloat(conn, key, increment),
    do: HotKV.command(conn, ["INCRBYFLOAT", key, to_arg(increment)])

  @doc "`DECR key` -> the value after decrementing."
  @spec decr(conn, key) :: {:ok, integer} | {:error, Error.t()}
  def decr(conn, key), do: HotKV.command(conn, ["DECR", key])

  @doc "`DECRBY key decrement` -> the value after decrementing."
  @spec decrby(conn, key, integer) :: {:ok, integer} | {:error, Error.t()}
  def decrby(conn, key, decrement), do: HotKV.command(conn, ["DECRBY", key, decrement])

  @doc "`MGET key [key ...]` -> a value per key, in order, `nil` for missing keys."
  @spec mget(conn, [key]) :: {:ok, [binary | nil]} | {:error, Error.t()}
  def mget(conn, keys), do: HotKV.command(conn, ["MGET" | keys])

  @doc "`MSET key value [key value ...]` -> `\"OK\"`. `pairs` is `[{key, value}, ...]` or a flat `[key, value, ...]` list."
  @spec mset(conn, [{key, binary}] | [binary]) :: {:ok, String.t()} | {:error, Error.t()}
  def mset(conn, pairs), do: HotKV.command(conn, ["MSET" | flatten_pairs(pairs)])

  @doc "`MSETNX key value [key value ...]` -> `true` only if every key was newly set (all-or-nothing)."
  @spec msetnx(conn, [{key, binary}] | [binary]) :: {:ok, boolean} | {:error, Error.t()}
  def msetnx(conn, pairs) do
    conn |> HotKV.command(["MSETNX" | flatten_pairs(pairs)]) |> Reply.map(&Reply.to_bool/1)
  end

  @doc "`GETRANGE key start end` -> the substring (standard, possibly negative, inclusive indices)."
  @spec getrange(conn, key, integer, integer) :: {:ok, binary} | {:error, Error.t()}
  def getrange(conn, key, start_index, end_index),
    do: HotKV.command(conn, ["GETRANGE", key, start_index, end_index])

  @doc "`SETRANGE key offset value` -> the length of the string after the write."
  @spec setrange(conn, key, non_neg_integer, binary) :: {:ok, integer} | {:error, Error.t()}
  def setrange(conn, key, offset, value),
    do: HotKV.command(conn, ["SETRANGE", key, offset, value])

  defp flatten_pairs([{_, _} | _] = pairs), do: Enum.flat_map(pairs, fn {k, v} -> [k, v] end)
  defp flatten_pairs(flat) when is_list(flat), do: flat

  defp to_arg(value) when is_float(value), do: HotKV.Numeric.format_float(value)
  defp to_arg(value), do: value
end
