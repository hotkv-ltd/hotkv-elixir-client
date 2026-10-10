# Copyright (c) 2026 HotKV Ltd
# Licensed under the Apache License, Version 2.0. See LICENSE in the project root.

defmodule HotKV.Sets do
  @moduledoc "Set commands."

  alias HotKV.{Args, Error, Reply, Scan}

  @type conn :: HotKV.conn()
  @type key :: String.t()

  @doc "`SADD key member [member ...]` -> the number of members newly added."
  @spec sadd(conn, key, binary | [binary]) :: {:ok, integer} | {:error, Error.t()}
  def sadd(conn, key, members), do: HotKV.command(conn, ["SADD", key | Args.wrap(members)])

  @doc "`SREM key member [member ...]` -> the number of members removed."
  @spec srem(conn, key, binary | [binary]) :: {:ok, integer} | {:error, Error.t()}
  def srem(conn, key, members), do: HotKV.command(conn, ["SREM", key | Args.wrap(members)])

  @doc "`SMEMBERS key` -> every member, as a `MapSet`."
  @spec smembers(conn, key) :: {:ok, MapSet.t()} | {:error, Error.t()}
  def smembers(conn, key),
    do: conn |> HotKV.command(["SMEMBERS", key]) |> Reply.map(&Reply.to_set/1)

  @doc "`SISMEMBER key member` -> `true` if `member` is in the set."
  @spec sismember(conn, key, binary) :: {:ok, boolean} | {:error, Error.t()}
  def sismember(conn, key, member),
    do: conn |> HotKV.command(["SISMEMBER", key, member]) |> Reply.map(&Reply.to_bool/1)

  @doc "`SMISMEMBER key member [member ...]` -> a boolean per member, in order."
  @spec smismember(conn, key, [binary]) :: {:ok, [boolean]} | {:error, Error.t()}
  def smismember(conn, key, members) do
    conn
    |> HotKV.command(["SMISMEMBER", key | members])
    |> Reply.map(&Enum.map(&1, fn v -> Reply.to_bool(v) end))
  end

  @doc "`SCARD key` -> the number of members, `0` if `key` does not exist."
  @spec scard(conn, key) :: {:ok, integer} | {:error, Error.t()}
  def scard(conn, key), do: HotKV.command(conn, ["SCARD", key])

  @doc "`SPOP key [count]` -> a random member (or list, with `count`), removed; `nil`/`[]` if empty."
  @spec spop(conn, key, non_neg_integer | nil) ::
          {:ok, binary | [binary] | nil} | {:error, Error.t()}
  def spop(conn, key, count \\ nil)
  def spop(conn, key, nil), do: HotKV.command(conn, ["SPOP", key])

  def spop(conn, key, count),
    do:
      conn |> HotKV.command(["SPOP", key, count]) |> Reply.map(&Reply.to_set/1) |> to_list_reply()

  @doc "`SRANDMEMBER key [count]` -> a random member (or list, with `count`, not removed)."
  @spec srandmember(conn, key, integer | nil) ::
          {:ok, binary | [binary] | nil} | {:error, Error.t()}
  def srandmember(conn, key, count \\ nil)
  def srandmember(conn, key, nil), do: HotKV.command(conn, ["SRANDMEMBER", key])
  def srandmember(conn, key, count), do: HotKV.command(conn, ["SRANDMEMBER", key, count])

  defp to_list_reply({:ok, %MapSet{} = set}), do: {:ok, MapSet.to_list(set)}
  defp to_list_reply(other), do: other

  @doc "`SUNION key [key ...]` -> the union, as a `MapSet`."
  @spec sunion(conn, key | [key]) :: {:ok, MapSet.t()} | {:error, Error.t()}
  def sunion(conn, keys),
    do: conn |> HotKV.command(["SUNION" | Args.wrap(keys)]) |> Reply.map(&Reply.to_set/1)

  @doc "`SUNIONSTORE destination key [key ...]` -> the size of the stored result."
  @spec sunionstore(conn, key, key | [key]) :: {:ok, integer} | {:error, Error.t()}
  def sunionstore(conn, destination, keys),
    do: HotKV.command(conn, ["SUNIONSTORE", destination | Args.wrap(keys)])

  @doc "`SINTER key [key ...]` -> the intersection, as a `MapSet`."
  @spec sinter(conn, key | [key]) :: {:ok, MapSet.t()} | {:error, Error.t()}
  def sinter(conn, keys),
    do: conn |> HotKV.command(["SINTER" | Args.wrap(keys)]) |> Reply.map(&Reply.to_set/1)

  @doc "`SINTERSTORE destination key [key ...]` -> the size of the stored result."
  @spec sinterstore(conn, key, key | [key]) :: {:ok, integer} | {:error, Error.t()}
  def sinterstore(conn, destination, keys),
    do: HotKV.command(conn, ["SINTERSTORE", destination | Args.wrap(keys)])

  @doc "`SINTERCARD numkeys key [key ...] [LIMIT limit]` -> the size of the intersection, without storing it."
  @spec sintercard(conn, [key], keyword) :: {:ok, integer} | {:error, Error.t()}
  def sintercard(conn, keys, opts \\ []) do
    extra = Args.value([], opts, :limit, "LIMIT")
    HotKV.command(conn, ["SINTERCARD", length(keys) | keys] ++ extra)
  end

  @doc "`SDIFF key [key ...]` -> the difference, as a `MapSet`."
  @spec sdiff(conn, key | [key]) :: {:ok, MapSet.t()} | {:error, Error.t()}
  def sdiff(conn, keys),
    do: conn |> HotKV.command(["SDIFF" | Args.wrap(keys)]) |> Reply.map(&Reply.to_set/1)

  @doc "`SDIFFSTORE destination key [key ...]` -> the size of the stored result."
  @spec sdiffstore(conn, key, key | [key]) :: {:ok, integer} | {:error, Error.t()}
  def sdiffstore(conn, destination, keys),
    do: HotKV.command(conn, ["SDIFFSTORE", destination | Args.wrap(keys)])

  @doc "`SMOVE source destination member` -> `true` if `member` was moved."
  @spec smove(conn, key, key, binary) :: {:ok, boolean} | {:error, Error.t()}
  def smove(conn, source, destination, member) do
    conn |> HotKV.command(["SMOVE", source, destination, member]) |> Reply.map(&Reply.to_bool/1)
  end

  @doc "A lazy `Stream` over every member of `key`, via `SSCAN`. `opts`: `:match`, `:count`."
  @spec sscan(conn, key, keyword) :: Enumerable.t()
  def sscan(conn, key, opts \\ []), do: Scan.stream(conn, ["SSCAN", key], opts)
end
