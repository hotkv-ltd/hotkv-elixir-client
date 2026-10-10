# Copyright (c) 2026 HotKV Ltd
# Licensed under the Apache License, Version 2.0. See LICENSE in the project root.

defmodule HotKV.Tag do
  @moduledoc "`TAG.*`: tagging arbitrary keys and querying by tag. Core, no license required."

  alias HotKV.{Error, Reply}

  @type conn :: HotKV.conn()

  @doc "`TAG.SET key tag [tag ...]` -> the number of tags newly added. `ERR no such key` if `key` does not exist."
  @spec set(conn, String.t(), String.t() | [String.t()]) :: {:ok, integer} | {:error, Error.t()}
  def set(conn, key, tags), do: HotKV.command(conn, ["TAG.SET", key | List.wrap(tags)])

  @doc "`TAG.REM key tag [tag ...]` -> the number of tags removed."
  @spec rem(conn, String.t(), String.t() | [String.t()]) :: {:ok, integer} | {:error, Error.t()}
  def rem(conn, key, tags), do: HotKV.command(conn, ["TAG.REM", key | List.wrap(tags)])

  @doc "`TAG.GET key` -> every tag on `key`."
  @spec get(conn, String.t()) :: {:ok, [String.t()]} | {:error, Error.t()}
  def get(conn, key), do: HotKV.command(conn, ["TAG.GET", key])

  @doc "`TAG.MEMBERS tag` -> every key carrying `tag`."
  @spec members(conn, String.t()) :: {:ok, [String.t()]} | {:error, Error.t()}
  def members(conn, tag), do: HotKV.command(conn, ["TAG.MEMBERS", tag])

  @doc "`TAG.INTER tag [tag ...]` -> keys carrying every given tag."
  @spec inter(conn, String.t() | [String.t()]) :: {:ok, [String.t()]} | {:error, Error.t()}
  def inter(conn, tags), do: HotKV.command(conn, ["TAG.INTER" | List.wrap(tags)])

  @doc "`TAG.COUNT key` -> the number of tags on `key`."
  @spec count(conn, String.t()) :: {:ok, integer} | {:error, Error.t()}
  def count(conn, key), do: HotKV.command(conn, ["TAG.COUNT", key])

  @doc "`TAG.EXISTS key tag` -> `true` if `key` carries `tag`."
  @spec exists?(conn, String.t(), String.t()) :: {:ok, boolean} | {:error, Error.t()}
  def exists?(conn, key, tag),
    do: conn |> HotKV.command(["TAG.EXISTS", key, tag]) |> Reply.map(&Reply.to_bool/1)
end
