# Copyright (c) 2026 HotKV Ltd
# Licensed under the Apache License, Version 2.0. See LICENSE in the project root.

defmodule HotKV.Streams do
  @moduledoc "Stream commands (`XADD`, consumer groups, ...)."

  alias HotKV.{Args, Error, Reply}

  @type conn :: HotKV.conn()
  @type key :: String.t()
  @type entry :: {String.t(), map}

  @doc """
  `XADD key [NOMKSTREAM] [MAXLEN|MINID [~] threshold [LIMIT n]] id field value [...]`
  -> the entry id. `id` is `"*"` for an auto-generated id. `fields` is
  `[{field, value}, ...]` or a flat list. `opts`: `:nomkstream`,
  `:maxlen`/`:minid` (pick one), `:approximate` (boolean, `~` vs `=`),
  `:trim_limit`.
  """
  @spec xadd(conn, key, String.t(), [{binary, binary}] | [binary], keyword) ::
          {:ok, String.t()} | {:error, Error.t()}
  def xadd(conn, key, id, fields, opts \\ []) do
    extra = [] |> Args.flag(opts, :nomkstream, "NOMKSTREAM") |> add_trim(opts)
    HotKV.command(conn, ["XADD", key | extra] ++ [id] ++ flatten_pairs(fields))
  end

  @doc "`XRANGE key start end [COUNT count]` -> `[{id, fields_map}, ...]`, oldest first."
  @spec xrange(conn, key, String.t(), String.t(), keyword) :: {:ok, [entry]} | {:error, Error.t()}
  def xrange(conn, key, start_id \\ "-", end_id \\ "+", opts \\ []) do
    extra = Args.value([], opts, :count, "COUNT")

    conn
    |> HotKV.command(["XRANGE", key, start_id, end_id | extra])
    |> Reply.map(&normalize_entries/1)
  end

  @doc "`XREVRANGE key end start [COUNT count]` -> `[{id, fields_map}, ...]`, newest first."
  @spec xrevrange(conn, key, String.t(), String.t(), keyword) ::
          {:ok, [entry]} | {:error, Error.t()}
  def xrevrange(conn, key, end_id \\ "+", start_id \\ "-", opts \\ []) do
    extra = Args.value([], opts, :count, "COUNT")

    conn
    |> HotKV.command(["XREVRANGE", key, end_id, start_id | extra])
    |> Reply.map(&normalize_entries/1)
  end

  @doc """
  `XREAD [COUNT n] [BLOCK ms] STREAMS key [key ...] id [id ...]` ->
  `%{stream_key => [{id, fields_map}, ...]}`, or `nil` on a `BLOCK` timeout.
  `streams` is `[{key, id}, ...]`.
  """
  @spec xread(conn, [{key, String.t()}], keyword) ::
          {:ok, %{key => [entry]} | nil} | {:error, Error.t()}
  def xread(conn, streams, opts \\ []) do
    extra = [] |> Args.value(opts, :count, "COUNT") |> Args.value(opts, :block, "BLOCK")
    {keys, ids} = Enum.unzip(streams)

    conn
    |> HotKV.command(["XREAD" | extra] ++ ["STREAMS" | keys] ++ ids, timeout: block_timeout(opts))
    |> Reply.map(&normalize_streams/1)
  end

  @doc """
  `XREADGROUP GROUP group consumer [COUNT n] [BLOCK ms] [NOACK] STREAMS key [key ...] id [id ...]`
  -> `%{stream_key => [{id, fields_map}, ...]}`, or `nil` on a `BLOCK` timeout.
  """
  @spec xreadgroup(conn, String.t(), String.t(), [{key, String.t()}], keyword) ::
          {:ok, %{key => [entry]} | nil} | {:error, Error.t()}
  def xreadgroup(conn, group, consumer, streams, opts \\ []) do
    extra =
      []
      |> Args.value(opts, :count, "COUNT")
      |> Args.value(opts, :block, "BLOCK")
      |> Args.flag(opts, :noack, "NOACK")

    {keys, ids} = Enum.unzip(streams)

    conn
    |> HotKV.command(
      ["XREADGROUP", "GROUP", group, consumer | extra] ++ ["STREAMS" | keys] ++ ids,
      timeout: block_timeout(opts)
    )
    |> Reply.map(&normalize_streams/1)
  end

  defp block_timeout(opts) do
    case Keyword.get(opts, :block) do
      nil -> 5_000
      0 -> :infinity
      ms -> ms + 5_000
    end
  end

  @doc "`XACK key group id [id ...]` -> the number of entries acknowledged."
  @spec xack(conn, key, String.t(), String.t() | [String.t()]) ::
          {:ok, integer} | {:error, Error.t()}
  def xack(conn, key, group, ids), do: HotKV.command(conn, ["XACK", key, group | List.wrap(ids)])

  @doc "`XGROUP CREATE key group id|$ [MKSTREAM]` -> `\"OK\"`. `opts`: `:mkstream` (boolean)."
  @spec xgroup_create(conn, key, String.t(), String.t(), keyword) ::
          {:ok, String.t()} | {:error, Error.t()}
  def xgroup_create(conn, key, group, id \\ "$", opts \\ []) do
    extra = Args.flag([], opts, :mkstream, "MKSTREAM")
    HotKV.command(conn, ["XGROUP", "CREATE", key, group, id | extra])
  end

  @doc "`XGROUP DESTROY key group` -> `true` if the group was destroyed."
  @spec xgroup_destroy(conn, key, String.t()) :: {:ok, boolean} | {:error, Error.t()}
  def xgroup_destroy(conn, key, group),
    do: conn |> HotKV.command(["XGROUP", "DESTROY", key, group]) |> Reply.map(&Reply.to_bool/1)

  @doc "`XGROUP CREATECONSUMER key group consumer` -> `true` if the consumer was created."
  @spec xgroup_createconsumer(conn, key, String.t(), String.t()) ::
          {:ok, boolean} | {:error, Error.t()}
  def xgroup_createconsumer(conn, key, group, consumer) do
    conn
    |> HotKV.command(["XGROUP", "CREATECONSUMER", key, group, consumer])
    |> Reply.map(&Reply.to_bool/1)
  end

  @doc "`XGROUP DELCONSUMER key group consumer` -> the number of pending entries that consumer had."
  @spec xgroup_delconsumer(conn, key, String.t(), String.t()) ::
          {:ok, integer} | {:error, Error.t()}
  def xgroup_delconsumer(conn, key, group, consumer),
    do: HotKV.command(conn, ["XGROUP", "DELCONSUMER", key, group, consumer])

  @doc "`XGROUP SETID key group id|$` -> `\"OK\"`."
  @spec xgroup_setid(conn, key, String.t(), String.t()) :: {:ok, String.t()} | {:error, Error.t()}
  def xgroup_setid(conn, key, group, id \\ "$"),
    do: HotKV.command(conn, ["XGROUP", "SETID", key, group, id])

  @doc "`XPENDING key group` -> the summary form: `[count, min_id, max_id, [{consumer, count}, ...] | nil]`."
  @spec xpending(conn, key, String.t()) :: {:ok, list} | {:error, Error.t()}
  def xpending(conn, key, group), do: HotKV.command(conn, ["XPENDING", key, group])

  @doc """
  `XPENDING key group [IDLE ms] start end count [consumer]` -> the extended
  form: a list of `[id, consumer, idle_ms, delivery_count]` entries.
  """
  @spec xpending(conn, key, String.t(), String.t(), String.t(), pos_integer, keyword) ::
          {:ok, list} | {:error, Error.t()}
  def xpending(conn, key, group, start_id, end_id, count, opts \\ []) do
    extra = Args.value([], opts, :idle, "IDLE")
    consumer_arg = if consumer = Keyword.get(opts, :consumer), do: [consumer], else: []

    HotKV.command(
      conn,
      ["XPENDING", key, group] ++ extra ++ [start_id, end_id, count] ++ consumer_arg
    )
  end

  @doc """
  `XCLAIM key group consumer min-idle-time id [id ...] [opts]` ->
  `[{id, fields_map}, ...]` (or a list of ids, with `opts[:justid]`).
  `opts`: `:idle`, `:time`, `:retrycount` (ms/integers), `:force`, `:justid`.
  """
  @spec xclaim(conn, key, String.t(), String.t(), integer, String.t() | [String.t()], keyword) ::
          {:ok, [entry] | [String.t()]} | {:error, Error.t()}
  def xclaim(conn, key, group, consumer, min_idle_time, ids, opts \\ []) do
    extra =
      []
      |> Args.value(opts, :idle, "IDLE")
      |> Args.value(opts, :time, "TIME")
      |> Args.value(opts, :retrycount, "RETRYCOUNT")
      |> Args.flag(opts, :force, "FORCE")
      |> Args.flag(opts, :justid, "JUSTID")

    result =
      HotKV.command(
        conn,
        ["XCLAIM", key, group, consumer, min_idle_time | List.wrap(ids)] ++ extra
      )

    if Keyword.get(opts, :justid), do: result, else: Reply.map(result, &normalize_entries/1)
  end

  @doc """
  `XAUTOCLAIM key group consumer min-idle-time start [COUNT n] [JUSTID]` ->
  `{next_cursor, entries_or_ids, deleted_ids}`.
  """
  @spec xautoclaim(conn, key, String.t(), String.t(), integer, String.t(), keyword) ::
          {:ok, {String.t(), [entry] | [String.t()], [String.t()]}} | {:error, Error.t()}
  def xautoclaim(conn, key, group, consumer, min_idle_time, start_id, opts \\ []) do
    extra = [] |> Args.value(opts, :count, "COUNT") |> Args.flag(opts, :justid, "JUSTID")

    conn
    |> HotKV.command(["XAUTOCLAIM", key, group, consumer, min_idle_time, start_id | extra])
    |> Reply.map(fn [cursor, entries, deleted] ->
      entries_out = if Keyword.get(opts, :justid), do: entries, else: normalize_entries(entries)
      {cursor, entries_out, deleted}
    end)
  end

  @doc "`XTRIM key MAXLEN|MINID [~] threshold [LIMIT n]` -> the number of entries removed. `opts` as in `xadd/5`."
  @spec xtrim(conn, key, keyword) :: {:ok, integer} | {:error, Error.t()}
  def xtrim(conn, key, opts \\ []), do: HotKV.command(conn, ["XTRIM", key | add_trim([], opts)])

  @doc "`XLEN key` -> the number of entries, `0` if `key` does not exist."
  @spec xlen(conn, key) :: {:ok, integer} | {:error, Error.t()}
  def xlen(conn, key), do: HotKV.command(conn, ["XLEN", key])

  @doc "`XDEL key id [id ...]` -> the number of entries removed."
  @spec xdel(conn, key, String.t() | [String.t()]) :: {:ok, integer} | {:error, Error.t()}
  def xdel(conn, key, ids), do: HotKV.command(conn, ["XDEL", key | List.wrap(ids)])

  @doc """
  `XCFGSET key [IDMP-DURATION seconds] [IDMP-MAXSIZE entries]` -> `"OK"`.
  Sets how long and how many idempotent ids a stream keeps for each
  producer. A server error if `key` does not exist. `opts`:
  `:idmp_duration` (seconds), `:idmp_maxsize` (entries).
  """
  @spec xcfgset(conn, key, keyword) :: {:ok, String.t()} | {:error, Error.t()}
  def xcfgset(conn, key, opts \\ []) do
    extra =
      []
      |> Args.value(opts, :idmp_duration, "IDMP-DURATION")
      |> Args.value(opts, :idmp_maxsize, "IDMP-MAXSIZE")

    HotKV.command(conn, ["XCFGSET", key | extra])
  end

  @doc "`XINFO STREAM key [FULL]` -> a map of the stream's info fields."
  @spec xinfo_stream(conn, key, keyword) :: {:ok, map} | {:error, Error.t()}
  def xinfo_stream(conn, key, opts \\ []) do
    extra = Args.flag([], opts, :full, "FULL")
    conn |> HotKV.command(["XINFO", "STREAM", key | extra]) |> Reply.map(&Reply.to_map/1)
  end

  @doc "`XINFO GROUPS key` -> one info map per consumer group."
  @spec xinfo_groups(conn, key) :: {:ok, [map]} | {:error, Error.t()}
  def xinfo_groups(conn, key) do
    conn
    |> HotKV.command(["XINFO", "GROUPS", key])
    |> Reply.map(&Enum.map(&1, fn g -> Reply.to_map(g) end))
  end

  @doc "`XINFO CONSUMERS key group` -> one info map per consumer."
  @spec xinfo_consumers(conn, key, String.t()) :: {:ok, [map]} | {:error, Error.t()}
  def xinfo_consumers(conn, key, group) do
    conn
    |> HotKV.command(["XINFO", "CONSUMERS", key, group])
    |> Reply.map(&Enum.map(&1, fn c -> Reply.to_map(c) end))
  end

  defp add_trim(acc, opts) do
    approx = if Keyword.get(opts, :approximate), do: "~", else: "="

    base =
      case {Keyword.get(opts, :maxlen), Keyword.get(opts, :minid)} do
        {nil, nil} -> nil
        {maxlen, nil} -> ["MAXLEN", approx, maxlen]
        {nil, minid} -> ["MINID", approx, minid]
      end

    case base do
      nil -> acc
      base -> acc ++ base ++ Args.value([], opts, :trim_limit, "LIMIT")
    end
  end

  defp normalize_entries(nil), do: nil

  defp normalize_entries(list) when is_list(list),
    do: Enum.map(list, fn [id, fields] -> {id, Reply.to_map(fields)} end)

  defp normalize_streams(nil), do: nil

  defp normalize_streams(map) when is_map(map),
    do: Map.new(map, fn {stream, entries} -> {stream, normalize_entries(entries)} end)

  defp normalize_streams(list) when is_list(list),
    do: Map.new(list, fn [stream, entries] -> {stream, normalize_entries(entries)} end)

  defp flatten_pairs([{_, _} | _] = pairs), do: Enum.flat_map(pairs, fn {k, v} -> [k, v] end)
  defp flatten_pairs(flat) when is_list(flat), do: flat
end
