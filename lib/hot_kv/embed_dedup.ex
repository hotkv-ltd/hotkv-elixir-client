# Copyright (c) 2026 HotKV Ltd
# Licensed under the Apache License, Version 2.0. See LICENSE in the project root.

defmodule HotKV.EmbedDedup do
  @moduledoc "`EMBED.DEDUP.*`: reference-counted embedding deduplication (needs a server license that includes the embed-dedup feature)."

  alias HotKV.{Error, Reply}

  @type conn :: HotKV.conn()

  @doc "`EMBED.DEDUP.PUT ns hash model embedding` -> `true` if newly stored, `false` if `hash` already existed (its refcount is incremented instead)."
  @spec put(conn, String.t(), String.t(), String.t(), binary) ::
          {:ok, boolean} | {:error, Error.t()}
  def put(conn, ns, hash, model, embedding) do
    conn
    |> HotKV.command(["EMBED.DEDUP.PUT", ns, hash, model, embedding])
    |> Reply.map(&Reply.to_bool/1)
  end

  @doc "`EMBED.DEDUP.GET ns hash` -> the stored embedding, `nil` if not found."
  @spec get(conn, String.t(), String.t()) :: {:ok, binary | nil} | {:error, Error.t()}
  def get(conn, ns, hash), do: HotKV.command(conn, ["EMBED.DEDUP.GET", ns, hash])

  @doc "`EMBED.DEDUP.RELEASE ns hash` -> `true` if it existed (its refcount is decremented; the entry is freed at 0)."
  @spec release(conn, String.t(), String.t()) :: {:ok, boolean} | {:error, Error.t()}
  def release(conn, ns, hash),
    do: conn |> HotKV.command(["EMBED.DEDUP.RELEASE", ns, hash]) |> Reply.map(&Reply.to_bool/1)

  @doc "`EMBED.DEDUP.STATS ns` -> `%{hits:, misses:, entries:}`."
  @spec stats(conn, String.t()) :: {:ok, map} | {:error, Error.t()}
  def stats(conn, ns),
    do: conn |> HotKV.command(["EMBED.DEDUP.STATS", ns]) |> Reply.map(&Reply.to_map/1)

  @doc "`EMBED.DEDUP.DROP ns` -> `true` if the namespace existed."
  @spec drop(conn, String.t()) :: {:ok, boolean} | {:error, Error.t()}
  def drop(conn, ns),
    do: conn |> HotKV.command(["EMBED.DEDUP.DROP", ns]) |> Reply.map(&Reply.to_bool/1)

  @doc "`EMBED.DEDUP.PURGE ns` -> `true` if the namespace existed. Purges expired/unreferenced entries."
  @spec purge(conn, String.t()) :: {:ok, boolean} | {:error, Error.t()}
  def purge(conn, ns),
    do: conn |> HotKV.command(["EMBED.DEDUP.PURGE", ns]) |> Reply.map(&Reply.to_bool/1)

  @doc "`EMBED.DEDUP.LIST` -> every namespace name."
  @spec list(conn) :: {:ok, [String.t()]} | {:error, Error.t()}
  def list(conn), do: HotKV.command(conn, ["EMBED.DEDUP.LIST"])
end
