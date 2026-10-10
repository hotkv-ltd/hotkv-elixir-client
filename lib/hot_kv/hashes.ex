# Copyright (c) 2026 HotKV Ltd
# Licensed under the Apache License, Version 2.0. See LICENSE in the project root.

defmodule HotKV.Hashes do
  @moduledoc "Hash commands, including the per-field expiry family (`HEXPIRE`/`HTTL`/...)."

  alias HotKV.{Args, Error, Reply, Scan}

  @type conn :: HotKV.conn()
  @type key :: String.t()

  @doc "`HSET key field value [field value ...]` -> the number of fields newly added. `pairs` is `[{field, value}, ...]` or a flat list."
  @spec hset(conn, key, [{binary, binary}] | [binary]) :: {:ok, integer} | {:error, Error.t()}
  def hset(conn, key, pairs), do: HotKV.command(conn, ["HSET", key | flatten_pairs(pairs)])

  @doc "`HSETNX key field value` -> `true` if the field was newly set."
  @spec hsetnx(conn, key, binary, binary) :: {:ok, boolean} | {:error, Error.t()}
  def hsetnx(conn, key, field, value),
    do: conn |> HotKV.command(["HSETNX", key, field, value]) |> Reply.map(&Reply.to_bool/1)

  @doc "`HGET key field` -> the value, `nil` if the field or key does not exist."
  @spec hget(conn, key, binary) :: {:ok, binary | nil} | {:error, Error.t()}
  def hget(conn, key, field), do: HotKV.command(conn, ["HGET", key, field])

  @doc "`HMGET key field [field ...]` -> a value per field, in order, `nil` for missing fields."
  @spec hmget(conn, key, [binary]) :: {:ok, [binary | nil]} | {:error, Error.t()}
  def hmget(conn, key, fields), do: HotKV.command(conn, ["HMGET", key | fields])

  @doc "`HGETALL key` -> every field/value pair, as a map."
  @spec hgetall(conn, key) :: {:ok, map} | {:error, Error.t()}
  def hgetall(conn, key),
    do: conn |> HotKV.command(["HGETALL", key]) |> Reply.map(&Reply.to_map/1)

  @doc "`HDEL key field [field ...]` -> the number of fields removed."
  @spec hdel(conn, key, binary | [binary]) :: {:ok, integer} | {:error, Error.t()}
  def hdel(conn, key, fields), do: HotKV.command(conn, ["HDEL", key | Args.wrap(fields)])

  @doc "`HEXISTS key field` -> `true` if the field exists."
  @spec hexists(conn, key, binary) :: {:ok, boolean} | {:error, Error.t()}
  def hexists(conn, key, field),
    do: conn |> HotKV.command(["HEXISTS", key, field]) |> Reply.map(&Reply.to_bool/1)

  @doc "`HKEYS key` -> every field name."
  @spec hkeys(conn, key) :: {:ok, [binary]} | {:error, Error.t()}
  def hkeys(conn, key), do: HotKV.command(conn, ["HKEYS", key])

  @doc "`HVALS key` -> every value."
  @spec hvals(conn, key) :: {:ok, [binary]} | {:error, Error.t()}
  def hvals(conn, key), do: HotKV.command(conn, ["HVALS", key])

  @doc "`HLEN key` -> the number of fields, `0` if `key` does not exist."
  @spec hlen(conn, key) :: {:ok, integer} | {:error, Error.t()}
  def hlen(conn, key), do: HotKV.command(conn, ["HLEN", key])

  @doc "`HSTRLEN key field` -> the value's length, `0` if the field or key does not exist."
  @spec hstrlen(conn, key, binary) :: {:ok, integer} | {:error, Error.t()}
  def hstrlen(conn, key, field), do: HotKV.command(conn, ["HSTRLEN", key, field])

  @doc "`HINCRBY key field increment` -> the value after incrementing."
  @spec hincrby(conn, key, binary, integer) :: {:ok, integer} | {:error, Error.t()}
  def hincrby(conn, key, field, increment),
    do: HotKV.command(conn, ["HINCRBY", key, field, increment])

  @doc "`HINCRBYFLOAT key field increment` -> the value after incrementing, as a string."
  @spec hincrbyfloat(conn, key, binary, float | String.t()) :: {:ok, binary} | {:error, Error.t()}
  def hincrbyfloat(conn, key, field, increment) do
    HotKV.command(conn, ["HINCRBYFLOAT", key, field, to_arg(increment)])
  end

  @doc """
  `HGETDEL key FIELDS numfields field [field ...]` -> the values of the
  fields (`nil` for a missing field) after deleting them atomically.
  """
  @spec hgetdel(conn, key, [binary]) :: {:ok, [binary | nil]} | {:error, Error.t()}
  def hgetdel(conn, key, fields),
    do: HotKV.command(conn, ["HGETDEL", key, "FIELDS", length(fields) | fields])

  @doc """
  `HGETEX key [EX|PX|EXAT|PXAT n|PERSIST] FIELDS numfields field [field ...]`
  -> the values of the fields (`nil` for a missing field), optionally
  setting or removing their TTLs. `opts`: `:ex`, `:px`, `:exat`, `:pxat`
  (integers), `:persist` (boolean).
  """
  @spec hgetex(conn, key, [binary], keyword) :: {:ok, [binary | nil]} | {:error, Error.t()}
  def hgetex(conn, key, fields, opts \\ []) do
    extra =
      []
      |> Args.value(opts, :ex, "EX")
      |> Args.value(opts, :px, "PX")
      |> Args.value(opts, :exat, "EXAT")
      |> Args.value(opts, :pxat, "PXAT")
      |> Args.flag(opts, :persist, "PERSIST")

    HotKV.command(conn, ["HGETEX", key] ++ extra ++ ["FIELDS", length(fields) | fields])
  end

  @doc """
  `HSETEX key [FNX|FXX] [EX|PX|EXAT|PXAT n|KEEPTTL] FIELDS numfields field value [...]`
  -> `true` if the fields were set (all or none), `false` if the `:fnx`
  (none of the fields may exist) or `:fxx` (all must exist) condition was
  not met. `pairs` is `[{field, value}, ...]` or a flat list. `opts`:
  `:fnx`, `:fxx`, `:keepttl` (booleans), `:ex`, `:px`, `:exat`, `:pxat`
  (integers).
  """
  @spec hsetex(conn, key, [{binary, binary}] | [binary], keyword) ::
          {:ok, boolean} | {:error, Error.t()}
  def hsetex(conn, key, pairs, opts \\ []) do
    flat = flatten_pairs(pairs)

    extra =
      []
      |> Args.flag(opts, :fnx, "FNX")
      |> Args.flag(opts, :fxx, "FXX")
      |> Args.value(opts, :ex, "EX")
      |> Args.value(opts, :px, "PX")
      |> Args.value(opts, :exat, "EXAT")
      |> Args.value(opts, :pxat, "PXAT")
      |> Args.flag(opts, :keepttl, "KEEPTTL")

    conn
    |> HotKV.command(["HSETEX", key] ++ extra ++ ["FIELDS", div(length(flat), 2) | flat])
    |> Reply.map(&Reply.to_bool/1)
  end

  @doc """
  `HRANDFIELD key [count [WITHVALUES]]` -> a random field (or list, with
  `count`; list of `{field, value}` with `opts[:with_values]`).
  """
  @spec hrandfield(conn, key, integer | nil, keyword) :: {:ok, term} | {:error, Error.t()}
  def hrandfield(conn, key, count \\ nil, opts \\ [])

  def hrandfield(conn, key, nil, _opts), do: HotKV.command(conn, ["HRANDFIELD", key])

  def hrandfield(conn, key, count, opts) do
    if Keyword.get(opts, :with_values) do
      conn
      |> HotKV.command(["HRANDFIELD", key, count, "WITHVALUES"])
      |> Reply.map(&Reply.to_pairs/1)
    else
      HotKV.command(conn, ["HRANDFIELD", key, count])
    end
  end

  @doc "A lazy `Stream` over `{field, value}` of `key`, via `HSCAN`. `opts`: `:match`, `:count`."
  @spec hscan(conn, key, keyword) :: Enumerable.t()
  def hscan(conn, key, opts \\ []) do
    conn
    |> Scan.stream(["HSCAN", key], opts)
    |> Stream.chunk_every(2)
    |> Stream.map(fn [k, v] -> {k, v} end)
  end

  @doc """
  `HEXPIRE key seconds [NX|XX|GT|LT] FIELDS numfields field [field ...]` ->
  one status integer per field (`1` set, `0` condition not met, `-2` no
  such field/key). `opts[:flag]` is one of `:nx`, `:xx`, `:gt`, `:lt`.
  """
  @spec hexpire(conn, key, integer, [binary], keyword) :: {:ok, [integer]} | {:error, Error.t()}
  def hexpire(conn, key, seconds, fields, opts \\ []),
    do: hfields_ttl_cmd(conn, "HEXPIRE", key, [seconds | flag_opt(opts)], fields)

  @doc "`HPEXPIRE key milliseconds [NX|XX|GT|LT] FIELDS numfields field [field ...]` -> one status integer per field."
  @spec hpexpire(conn, key, integer, [binary], keyword) :: {:ok, [integer]} | {:error, Error.t()}
  def hpexpire(conn, key, milliseconds, fields, opts \\ []),
    do: hfields_ttl_cmd(conn, "HPEXPIRE", key, [milliseconds | flag_opt(opts)], fields)

  @doc "`HEXPIREAT key unix_seconds [NX|XX|GT|LT] FIELDS numfields field [field ...]` -> one status integer per field."
  @spec hexpireat(conn, key, integer, [binary], keyword) :: {:ok, [integer]} | {:error, Error.t()}
  def hexpireat(conn, key, unix_seconds, fields, opts \\ []),
    do: hfields_ttl_cmd(conn, "HEXPIREAT", key, [unix_seconds | flag_opt(opts)], fields)

  @doc "`HPEXPIREAT key unix_milliseconds [NX|XX|GT|LT] FIELDS numfields field [field ...]` -> one status integer per field."
  @spec hpexpireat(conn, key, integer, [binary], keyword) ::
          {:ok, [integer]} | {:error, Error.t()}
  def hpexpireat(conn, key, unix_milliseconds, fields, opts \\ []),
    do: hfields_ttl_cmd(conn, "HPEXPIREAT", key, [unix_milliseconds | flag_opt(opts)], fields)

  @doc "`HPERSIST key FIELDS numfields field [field ...]` -> one status integer per field."
  @spec hpersist(conn, key, [binary]) :: {:ok, [integer]} | {:error, Error.t()}
  def hpersist(conn, key, fields), do: hfields_ttl_cmd(conn, "HPERSIST", key, [], fields)

  @doc "`HTTL key FIELDS numfields field [field ...]` -> remaining seconds per field (`-1` no expiry, `-2` no such field)."
  @spec httl(conn, key, [binary]) :: {:ok, [integer]} | {:error, Error.t()}
  def httl(conn, key, fields), do: hfields_ttl_cmd(conn, "HTTL", key, [], fields)

  @doc "`HPTTL key FIELDS numfields field [field ...]` -> remaining milliseconds per field."
  @spec hpttl(conn, key, [binary]) :: {:ok, [integer]} | {:error, Error.t()}
  def hpttl(conn, key, fields), do: hfields_ttl_cmd(conn, "HPTTL", key, [], fields)

  @doc "`HEXPIRETIME key FIELDS numfields field [field ...]` -> absolute expiry (Unix seconds) per field."
  @spec hexpiretime(conn, key, [binary]) :: {:ok, [integer]} | {:error, Error.t()}
  def hexpiretime(conn, key, fields), do: hfields_ttl_cmd(conn, "HEXPIRETIME", key, [], fields)

  @doc "`HPEXPIRETIME key FIELDS numfields field [field ...]` -> absolute expiry (Unix milliseconds) per field."
  @spec hpexpiretime(conn, key, [binary]) :: {:ok, [integer]} | {:error, Error.t()}
  def hpexpiretime(conn, key, fields), do: hfields_ttl_cmd(conn, "HPEXPIRETIME", key, [], fields)

  defp hfields_ttl_cmd(conn, name, key, middle_args, fields) do
    HotKV.command(conn, [name, key] ++ middle_args ++ ["FIELDS", length(fields) | fields])
  end

  defp flag_opt(opts) do
    case Keyword.get(opts, :flag) do
      nil -> []
      flag when flag in [:nx, :xx, :gt, :lt] -> [flag |> Atom.to_string() |> String.upcase()]
    end
  end

  defp flatten_pairs([{_, _} | _] = pairs), do: Enum.flat_map(pairs, fn {k, v} -> [k, v] end)
  defp flatten_pairs(flat) when is_list(flat), do: flat

  defp to_arg(value) when is_float(value), do: HotKV.Numeric.format_float(value)
  defp to_arg(value), do: value
end
