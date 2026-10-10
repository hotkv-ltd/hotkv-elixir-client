# Copyright (c) 2026 HotKV Ltd
# Licensed under the Apache License, Version 2.0. See LICENSE in the project root.

defmodule HotKV.NegativeCache do
  @moduledoc "`NCACHE.*`: negative (\"don't retry\") cache (needs a server license that includes the negative-cache feature)."

  alias HotKV.Error
  alias HotKV.KeyedCache, as: Engine

  @type conn :: HotKV.conn()

  @doc "`NCACHE.CREATE ns [MAX_ENTRIES n] [TTL seconds]` -> `\"OK\"`."
  @spec create(conn, String.t(), keyword) :: {:ok, String.t()} | {:error, Error.t()}
  def create(conn, ns, opts \\ []), do: Engine.create(conn, "NCACHE", ns, opts)

  @doc """
  `NCACHE.SET ns key value [TTL seconds] [META json] [usage group]` ->
  `\"OK\"`. `opts`: `:ttl`, `:meta`, `:usage` (a `HotKV.TokenUsage`: records
  the original, uncached call's token usage so a later hit attributes it,
  and its cost once the model is priced, to `stats/2`'s `usage_saved_*`
  counters).
  """
  @spec set(conn, String.t(), String.t(), String.t(), keyword) ::
          {:ok, String.t()} | {:error, Error.t()}
  def set(conn, ns, key, value, opts \\ []), do: Engine.set(conn, "NCACHE", ns, key, value, opts)

  @doc "`NCACHE.GET ns key` -> the cached value, `nil` on a miss."
  @spec get(conn, String.t(), String.t()) :: {:ok, String.t() | nil} | {:error, Error.t()}
  def get(conn, ns, key), do: Engine.get(conn, "NCACHE", ns, key)

  @doc "`NCACHE.DEL ns key` -> `true` if an entry was removed."
  @spec del(conn, String.t(), String.t()) :: {:ok, boolean} | {:error, Error.t()}
  def del(conn, ns, key), do: Engine.del(conn, "NCACHE", ns, key)

  @doc """
  `NCACHE.STATS ns` -> `%{entries:, hits:, misses:, evictions:,
  memory_bytes:, usage_saved_requests:, usage_saved_input_tokens:,
  usage_saved_output_tokens:, usage_saved_cache_read_tokens:,
  usage_saved_cache_write_tokens:, usage_saved_cost_usd:}`.
  """
  @spec stats(conn, String.t()) :: {:ok, map} | {:error, Error.t()}
  def stats(conn, ns), do: Engine.stats(conn, "NCACHE", ns)

  @doc "`NCACHE.FLUSH ns` -> the number of entries flushed."
  @spec flush(conn, String.t()) :: {:ok, integer} | {:error, Error.t()}
  def flush(conn, ns), do: Engine.flush(conn, "NCACHE", ns)

  @doc "`NCACHE.DROP ns` -> `true` if the namespace existed."
  @spec drop(conn, String.t()) :: {:ok, boolean} | {:error, Error.t()}
  def drop(conn, ns), do: Engine.drop(conn, "NCACHE", ns)

  @doc "`NCACHE.LIST` -> every namespace name."
  @spec list(conn) :: {:ok, [String.t()]} | {:error, Error.t()}
  def list(conn), do: Engine.list(conn, "NCACHE")
end
