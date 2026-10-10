# Copyright (c) 2026 HotKV Ltd
# Licensed under the Apache License, Version 2.0. See LICENSE in the project root.

defmodule HotKV.Keys do
  @moduledoc """
  Generic key commands: existence, expiry, type, renaming, scanning and
  migration (`DUMP`/`RESTORE`/`COPY`).
  """

  alias HotKV.{Error, Reply, Scan}

  @type conn :: HotKV.conn()
  @type key :: String.t()

  @doc "`DEL key [key ...]` -> number of keys removed."
  @spec del(conn, key | [key]) :: {:ok, integer} | {:error, Error.t()}
  def del(conn, keys), do: HotKV.command(conn, ["DEL" | List.wrap(keys)])

  @doc "`UNLINK key [key ...]` -> number of keys removed (non-blocking reclaim)."
  @spec unlink(conn, key | [key]) :: {:ok, integer} | {:error, Error.t()}
  def unlink(conn, keys), do: HotKV.command(conn, ["UNLINK" | List.wrap(keys)])

  @doc "`EXISTS key [key ...]` -> number of the given keys that exist (a repeated key counts twice)."
  @spec exists(conn, key | [key]) :: {:ok, integer} | {:error, Error.t()}
  def exists(conn, keys), do: HotKV.command(conn, ["EXISTS" | List.wrap(keys)])

  @doc "`TOUCH key [key ...]` -> number of keys touched."
  @spec touch(conn, key | [key]) :: {:ok, integer} | {:error, Error.t()}
  def touch(conn, keys), do: HotKV.command(conn, ["TOUCH" | List.wrap(keys)])

  @doc "`TYPE key` -> the value's type name (`\"string\"`, `\"hash\"`, ...), or `\"none\"`."
  @spec type(conn, key) :: {:ok, String.t()} | {:error, Error.t()}
  def type(conn, key), do: HotKV.command(conn, ["TYPE", key])

  @doc "`RANDOMKEY` -> a random key, or `nil` if the keyspace is empty."
  @spec randomkey(conn) :: {:ok, String.t() | nil} | {:error, Error.t()}
  def randomkey(conn), do: HotKV.command(conn, ["RANDOMKEY"])

  @doc "`KEYS pattern` -> every key matching the glob `pattern`. Prefer `scan/2` outside small/test datasets."
  @spec keys(conn, String.t()) :: {:ok, [String.t()]} | {:error, Error.t()}
  def keys(conn, pattern), do: HotKV.command(conn, ["KEYS", pattern])

  @doc """
  A lazy `Stream` over every key, via `SCAN`. `opts`: `:match`, `:count`,
  `:type` (restrict to one value type). See `HotKV.Scan.stream/3`.
  """
  @spec scan(conn, keyword) :: Enumerable.t()
  def scan(conn, opts \\ []), do: Scan.stream(conn, ["SCAN"], opts)

  @doc "`RENAME key newkey` -> `:ok`, or a `server` error if `key` does not exist."
  @spec rename(conn, key, key) :: {:ok, String.t()} | {:error, Error.t()}
  def rename(conn, key, newkey), do: HotKV.command(conn, ["RENAME", key, newkey])

  @doc "`RENAMENX key newkey` -> `true` if renamed, `false` if `newkey` already exists."
  @spec renamenx(conn, key, key) :: {:ok, boolean} | {:error, Error.t()}
  def renamenx(conn, key, newkey) do
    conn |> HotKV.command(["RENAMENX", key, newkey]) |> Reply.map(&Reply.to_bool/1)
  end

  @doc """
  `EXPIRE key seconds [NX|XX|GT|LT]` -> `true` if the timeout was set.
  `opts[:flag]` is one of `:nx`, `:xx`, `:gt`, `:lt`.
  """
  @spec expire(conn, key, integer, keyword) :: {:ok, boolean} | {:error, Error.t()}
  def expire(conn, key, seconds, opts \\ []) do
    conn
    |> HotKV.command(["EXPIRE", key, seconds | flag_opt(opts)])
    |> Reply.map(&Reply.to_bool/1)
  end

  @doc "`PEXPIRE key milliseconds [NX|XX|GT|LT]` -> `true` if the timeout was set."
  @spec pexpire(conn, key, integer, keyword) :: {:ok, boolean} | {:error, Error.t()}
  def pexpire(conn, key, milliseconds, opts \\ []) do
    conn
    |> HotKV.command(["PEXPIRE", key, milliseconds | flag_opt(opts)])
    |> Reply.map(&Reply.to_bool/1)
  end

  @doc "`EXPIREAT key unix_seconds [NX|XX|GT|LT]` -> `true` if the timeout was set."
  @spec expireat(conn, key, integer, keyword) :: {:ok, boolean} | {:error, Error.t()}
  def expireat(conn, key, unix_seconds, opts \\ []) do
    conn
    |> HotKV.command(["EXPIREAT", key, unix_seconds | flag_opt(opts)])
    |> Reply.map(&Reply.to_bool/1)
  end

  @doc "`PEXPIREAT key unix_milliseconds [NX|XX|GT|LT]` -> `true` if the timeout was set."
  @spec pexpireat(conn, key, integer, keyword) :: {:ok, boolean} | {:error, Error.t()}
  def pexpireat(conn, key, unix_milliseconds, opts \\ []) do
    conn
    |> HotKV.command(["PEXPIREAT", key, unix_milliseconds | flag_opt(opts)])
    |> Reply.map(&Reply.to_bool/1)
  end

  defp flag_opt(opts) do
    case Keyword.get(opts, :flag) do
      nil -> []
      flag when flag in [:nx, :xx, :gt, :lt] -> [flag |> Atom.to_string() |> String.upcase()]
    end
  end

  @doc "`PERSIST key` -> `true` if an existing timeout was removed."
  @spec persist(conn, key) :: {:ok, boolean} | {:error, Error.t()}
  def persist(conn, key),
    do: conn |> HotKV.command(["PERSIST", key]) |> Reply.map(&Reply.to_bool/1)

  @doc "`TTL key` -> remaining seconds, `-1` if no expiry, `-2` if `key` does not exist."
  @spec ttl(conn, key) :: {:ok, integer} | {:error, Error.t()}
  def ttl(conn, key), do: HotKV.command(conn, ["TTL", key])

  @doc "`PTTL key` -> remaining milliseconds, `-1` if no expiry, `-2` if `key` does not exist."
  @spec pttl(conn, key) :: {:ok, integer} | {:error, Error.t()}
  def pttl(conn, key), do: HotKV.command(conn, ["PTTL", key])

  @doc "`EXPIRETIME key` -> absolute expiry as a Unix timestamp in seconds, `-1`/`-2` as with `TTL`."
  @spec expiretime(conn, key) :: {:ok, integer} | {:error, Error.t()}
  def expiretime(conn, key), do: HotKV.command(conn, ["EXPIRETIME", key])

  @doc "`PEXPIRETIME key` -> absolute expiry as a Unix timestamp in milliseconds, `-1`/`-2` as with `TTL`."
  @spec pexpiretime(conn, key) :: {:ok, integer} | {:error, Error.t()}
  def pexpiretime(conn, key), do: HotKV.command(conn, ["PEXPIRETIME", key])

  @doc "`DUMP key` -> the serialized value, or `nil` if `key` does not exist."
  @spec dump(conn, key) :: {:ok, binary | nil} | {:error, Error.t()}
  def dump(conn, key), do: HotKV.command(conn, ["DUMP", key])

  @doc """
  `RESTORE key ttl serialized_value [opts]` -> `:ok`. `ttl` is milliseconds
  (`0` for no expiry). `opts`: `:replace` (boolean), `:absttl` (boolean,
  `ttl` is an absolute Unix timestamp), `:idletime` (seconds), `:freq`.
  """
  @spec restore(conn, key, non_neg_integer, binary, keyword) ::
          {:ok, String.t()} | {:error, Error.t()}
  def restore(conn, key, ttl, serialized_value, opts \\ []) do
    extra =
      []
      |> add_flag("REPLACE", Keyword.get(opts, :replace))
      |> add_flag("ABSTTL", Keyword.get(opts, :absttl))
      |> add_kw("IDLETIME", Keyword.get(opts, :idletime))
      |> add_kw("FREQ", Keyword.get(opts, :freq))

    HotKV.command(conn, ["RESTORE", key, ttl, serialized_value | extra])
  end

  @doc """
  `COPY source destination [DB db] [REPLACE]` -> `true` if copied.
  `opts`: `:db` (integer), `:replace` (boolean).
  """
  @spec copy(conn, key, key, keyword) :: {:ok, boolean} | {:error, Error.t()}
  def copy(conn, source, destination, opts \\ []) do
    extra =
      []
      |> add_kw("DB", Keyword.get(opts, :db))
      |> add_flag("REPLACE", Keyword.get(opts, :replace))

    conn |> HotKV.command(["COPY", source, destination | extra]) |> Reply.map(&Reply.to_bool/1)
  end

  @doc "`MOVE key db` -> `true` if moved to database `db`."
  @spec move(conn, key, integer) :: {:ok, boolean} | {:error, Error.t()}
  def move(conn, key, db),
    do: conn |> HotKV.command(["MOVE", key, db]) |> Reply.map(&Reply.to_bool/1)

  @doc "`OBJECT ENCODING key` -> the internal encoding name, or `nil` if `key` does not exist."
  @spec object_encoding(conn, key) :: {:ok, String.t() | nil} | {:error, Error.t()}
  def object_encoding(conn, key), do: HotKV.command(conn, ["OBJECT", "ENCODING", key])

  defp add_flag(acc, _kw, falsy) when falsy in [nil, false], do: acc
  defp add_flag(acc, kw, true), do: acc ++ [kw]

  defp add_kw(acc, _kw, nil), do: acc
  defp add_kw(acc, kw, value), do: acc ++ [kw, value]
end
