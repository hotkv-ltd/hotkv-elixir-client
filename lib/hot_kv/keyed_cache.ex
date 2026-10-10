# Copyright (c) 2026 HotKV Ltd
# Licensed under the Apache License, Version 2.0. See LICENSE in the project root.

defmodule HotKV.KeyedCache do
  @moduledoc false
  # Shared engine behind the four identically-shaped keyed cache command
  # families: TOOL.CACHE.* (HotKV.ToolCache), NCACHE.* (HotKV.NegativeCache),
  # GUARD.* (HotKV.GuardCache) and RERANK.* (HotKV.RerankCache).

  alias HotKV.{Args, Reply}

  def create(conn, prefix, ns, opts) do
    extra = [] |> Args.value(opts, :max_entries, "MAX_ENTRIES") |> Args.value(opts, :ttl, "TTL")
    HotKV.command(conn, ["#{prefix}.CREATE", ns | extra])
  end

  def set(conn, prefix, ns, key, value, opts) do
    extra =
      [] |> Args.value(opts, :ttl, "TTL") |> Args.value(opts, :meta, "META") |> Args.usage(opts)

    HotKV.command(conn, ["#{prefix}.SET", ns, key, value | extra])
  end

  def get(conn, prefix, ns, key), do: HotKV.command(conn, ["#{prefix}.GET", ns, key])

  def del(conn, prefix, ns, key),
    do: conn |> HotKV.command(["#{prefix}.DEL", ns, key]) |> Reply.map(&Reply.to_bool/1)

  def stats(conn, prefix, ns),
    do: conn |> HotKV.command(["#{prefix}.STATS", ns]) |> Reply.map(&Reply.to_map/1)

  def flush(conn, prefix, ns), do: HotKV.command(conn, ["#{prefix}.FLUSH", ns])

  def drop(conn, prefix, ns),
    do: conn |> HotKV.command(["#{prefix}.DROP", ns]) |> Reply.map(&Reply.to_bool/1)

  def list(conn, prefix), do: HotKV.command(conn, ["#{prefix}.LIST"])
end
