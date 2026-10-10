# Copyright (c) 2026 HotKV Ltd
# Licensed under the Apache License, Version 2.0. See LICENSE in the project root.

defmodule HotKV.AgentMemory do
  @moduledoc """
  `AMEM.*`: AI agent memory (needs a server license that includes the
  agent-memory feature), covering conversation, semantic, working and
  episodic memory, cross-memory search, and rolling conversation summaries
  (`AMEM.SUMMARY.*`, which need the summary feature in the license).
  """

  alias HotKV.{Args, Error, Reply}

  @type conn :: HotKV.conn()
  @type vector :: [float | integer]

  # -- conversation memory ------------------------------------------------

  @doc "`AMEM.CONV.CREATE session_id [WINDOW size] [TTL seconds]` -> `\"OK\"`, or a server error if the session already exists."
  @spec conv_create(conn, String.t(), keyword) :: {:ok, String.t()} | {:error, Error.t()}
  def conv_create(conn, session_id, opts \\ []) do
    extra = [] |> Args.value(opts, :window, "WINDOW") |> Args.value(opts, :ttl, "TTL")
    HotKV.command(conn, ["AMEM.CONV.CREATE", session_id | extra])
  end

  @doc "`AMEM.CONV.APPEND session_id role content` -> `\"OK\"`, or a server error if the session does not exist."
  @spec conv_append(conn, String.t(), String.t(), String.t()) ::
          {:ok, String.t()} | {:error, Error.t()}
  def conv_append(conn, session_id, role, content),
    do: HotKV.command(conn, ["AMEM.CONV.APPEND", session_id, role, content])

  @doc "`AMEM.CONV.GET session_id` -> `[%{role:, content:}, ...]`, oldest first."
  @spec conv_get(conn, String.t()) ::
          {:ok, [%{role: String.t(), content: String.t()}]} | {:error, Error.t()}
  def conv_get(conn, session_id),
    do: conn |> HotKV.command(["AMEM.CONV.GET", session_id]) |> Reply.map(&turns/1)

  @doc "`AMEM.CONV.WINDOW session_id n` -> `[%{role:, content:}, ...]`, the last `n` turns."
  @spec conv_window(conn, String.t(), pos_integer) ::
          {:ok, [%{role: String.t(), content: String.t()}]} | {:error, Error.t()}
  def conv_window(conn, session_id, n),
    do: conn |> HotKV.command(["AMEM.CONV.WINDOW", session_id, n]) |> Reply.map(&turns/1)

  defp turns(list),
    do:
      Enum.map(list, fn ["role", role, "content", content] -> %{role: role, content: content} end)

  @doc "`AMEM.CONV.CLEAR session_id` -> `true` if the session existed."
  @spec conv_clear(conn, String.t()) :: {:ok, boolean} | {:error, Error.t()}
  def conv_clear(conn, session_id),
    do: conn |> HotKV.command(["AMEM.CONV.CLEAR", session_id]) |> Reply.map(&Reply.to_bool/1)

  @doc "`AMEM.CONV.DROP session_id` -> `true` if the session existed."
  @spec conv_drop(conn, String.t()) :: {:ok, boolean} | {:error, Error.t()}
  def conv_drop(conn, session_id),
    do: conn |> HotKV.command(["AMEM.CONV.DROP", session_id]) |> Reply.map(&Reply.to_bool/1)

  # -- semantic memory (per-agent vector store) ---------------------------

  @doc "`AMEM.SEM.CREATE agent_id dimensions` -> `\"OK\"`, or a server error if the store already exists. `dimensions` in `1..65536`."
  @spec sem_create(conn, String.t(), pos_integer) :: {:ok, String.t()} | {:error, Error.t()}
  def sem_create(conn, agent_id, dimensions),
    do: HotKV.command(conn, ["AMEM.SEM.CREATE", agent_id, dimensions])

  @doc "`AMEM.SEM.STORE agent_id key content val1 ... valN [TTL seconds]` -> `\"OK\"`."
  @spec sem_store(conn, String.t(), String.t(), String.t(), vector, pos_integer | nil) ::
          {:ok, String.t()} | {:error, Error.t()}
  def sem_store(conn, agent_id, key, content, vector, ttl \\ nil) do
    extra = if ttl, do: ["TTL", ttl], else: []
    HotKV.command(conn, ["AMEM.SEM.STORE", agent_id, key, content | vector_args(vector)] ++ extra)
  end

  @doc "`AMEM.SEM.RECALL agent_id k val1 ... valN` -> `[%{key:, content:, similarity:}, ...]`, most similar first."
  @spec sem_recall(conn, String.t(), pos_integer, vector) :: {:ok, [map]} | {:error, Error.t()}
  def sem_recall(conn, agent_id, k, vector) do
    conn
    |> HotKV.command(["AMEM.SEM.RECALL", agent_id, k | vector_args(vector)])
    |> Reply.map(fn list ->
      Enum.map(list, fn ["key", key, "content", content, "similarity", sim] ->
        %{key: key, content: content, similarity: Reply.to_double(sim)}
      end)
    end)
  end

  @doc "`AMEM.SEM.FORGET agent_id key` -> `true` if it existed."
  @spec sem_forget(conn, String.t(), String.t()) :: {:ok, boolean} | {:error, Error.t()}
  def sem_forget(conn, agent_id, key),
    do: conn |> HotKV.command(["AMEM.SEM.FORGET", agent_id, key]) |> Reply.map(&Reply.to_bool/1)

  @doc "`AMEM.SEM.LIST agent_id` -> every stored key."
  @spec sem_list(conn, String.t()) :: {:ok, [String.t()]} | {:error, Error.t()}
  def sem_list(conn, agent_id), do: HotKV.command(conn, ["AMEM.SEM.LIST", agent_id])

  # -- working memory (per-session scratch key/value) ----------------------

  @doc "`AMEM.WORK.SET session_id key value [TTL seconds]` -> `\"OK\"`."
  @spec work_set(conn, String.t(), String.t(), String.t(), pos_integer | nil) ::
          {:ok, String.t()} | {:error, Error.t()}
  def work_set(conn, session_id, key, value, ttl \\ nil) do
    extra = if ttl, do: ["TTL", ttl], else: []
    HotKV.command(conn, ["AMEM.WORK.SET", session_id, key, value | extra])
  end

  @doc "`AMEM.WORK.GET session_id key` -> the value, `nil` on a miss (an empty stored value is also `nil`)."
  @spec work_get(conn, String.t(), String.t()) :: {:ok, String.t() | nil} | {:error, Error.t()}
  def work_get(conn, session_id, key), do: HotKV.command(conn, ["AMEM.WORK.GET", session_id, key])

  @doc "`AMEM.WORK.DEL session_id key` -> `true` if it existed."
  @spec work_del(conn, String.t(), String.t()) :: {:ok, boolean} | {:error, Error.t()}
  def work_del(conn, session_id, key),
    do: conn |> HotKV.command(["AMEM.WORK.DEL", session_id, key]) |> Reply.map(&Reply.to_bool/1)

  @doc "`AMEM.WORK.CLEAR session_id` -> `true` if the session exists (it stays registered, empty, after the clear), `false` if it was never created."
  @spec work_clear(conn, String.t()) :: {:ok, boolean} | {:error, Error.t()}
  def work_clear(conn, session_id),
    do: conn |> HotKV.command(["AMEM.WORK.CLEAR", session_id]) |> Reply.map(&Reply.to_bool/1)

  @doc "`AMEM.WORK.LIST session_id` -> every key."
  @spec work_list(conn, String.t()) :: {:ok, [String.t()]} | {:error, Error.t()}
  def work_list(conn, session_id), do: HotKV.command(conn, ["AMEM.WORK.LIST", session_id])

  # -- episodic memory (append-only event log) -----------------------------

  @doc "`AMEM.EPIS.LOG agent_id event_type content [METADATA json]` -> `\"OK\"`."
  @spec epis_log(conn, String.t(), String.t(), String.t(), String.t() | nil) ::
          {:ok, String.t()} | {:error, Error.t()}
  def epis_log(conn, agent_id, event_type, content, metadata \\ nil) do
    extra = if metadata, do: ["METADATA", metadata], else: []
    HotKV.command(conn, ["AMEM.EPIS.LOG", agent_id, event_type, content | extra])
  end

  @doc """
  `AMEM.EPIS.QUERY agent_id [TYPE event_type] [FROM ts] [TO ts] [LIMIT n]`
  -> `[%{type:, content:, metadata:, timestamp:}, ...]`.
  """
  @spec epis_query(conn, String.t(), keyword) :: {:ok, [map]} | {:error, Error.t()}
  def epis_query(conn, agent_id, opts \\ []) do
    extra =
      []
      |> Args.value(opts, :type, "TYPE")
      |> Args.value(opts, :from, "FROM")
      |> Args.value(opts, :to, "TO")
      |> Args.value(opts, :limit, "LIMIT")

    conn
    |> HotKV.command(["AMEM.EPIS.QUERY", agent_id | extra])
    |> Reply.map(fn list ->
      Enum.map(list, fn ["type", type, "content", content, "metadata", metadata, "timestamp", ts] ->
        %{type: type, content: content, metadata: metadata, timestamp: ts}
      end)
    end)
  end

  @doc "`AMEM.EPIS.CLEAR agent_id` -> `true` if any events existed."
  @spec epis_clear(conn, String.t()) :: {:ok, boolean} | {:error, Error.t()}
  def epis_clear(conn, agent_id),
    do: conn |> HotKV.command(["AMEM.EPIS.CLEAR", agent_id]) |> Reply.map(&Reply.to_bool/1)

  @doc "`AMEM.EPIS.STATS agent_id` -> `%{total_events:, oldest_ts:, newest_ts:}`."
  @spec epis_stats(conn, String.t()) :: {:ok, map} | {:error, Error.t()}
  def epis_stats(conn, agent_id),
    do: conn |> HotKV.command(["AMEM.EPIS.STATS", agent_id]) |> Reply.map(&Reply.to_map/1)

  # -- cross-memory search --------------------------------------------------

  @doc """
  `AMEM.SEARCH agent_id k val1 ... valN` -> `[%{source:, key:, content:,
  similarity:}, ...]`, searching semantic, episodic and working memory
  together, most similar first.
  """
  @spec search(conn, String.t(), pos_integer, vector) :: {:ok, [map]} | {:error, Error.t()}
  def search(conn, agent_id, k, vector) do
    conn
    |> HotKV.command(["AMEM.SEARCH", agent_id, k | vector_args(vector)])
    |> Reply.map(fn list ->
      Enum.map(list, fn ["source", source, "key", key, "content", content, "similarity", sim] ->
        %{source: source, key: key, content: content, similarity: Reply.to_double(sim)}
      end)
    end)
  end

  # -- rolling summaries (AMEM.SUMMARY.*, needs the summary license feature) ---------

  @doc "`AMEM.SUMMARY.SET agent_id summary` -> the new version number."
  @spec summary_set(conn, String.t(), String.t()) :: {:ok, integer} | {:error, Error.t()}
  def summary_set(conn, agent_id, summary),
    do: HotKV.command(conn, ["AMEM.SUMMARY.SET", agent_id, summary])

  @doc "`AMEM.SUMMARY.APPEND agent_id extra` -> the new version number (appends to the stored summary text)."
  @spec summary_append(conn, String.t(), String.t()) :: {:ok, integer} | {:error, Error.t()}
  def summary_append(conn, agent_id, extra),
    do: HotKV.command(conn, ["AMEM.SUMMARY.APPEND", agent_id, extra])

  @doc "`AMEM.SUMMARY.GET agent_id` -> `%{summary:, version:, updated_unix:}`, `nil` if not found."
  @spec summary_get(conn, String.t()) :: {:ok, map | nil} | {:error, Error.t()}
  def summary_get(conn, agent_id) do
    conn
    |> HotKV.command(["AMEM.SUMMARY.GET", agent_id])
    |> Reply.map(fn
      nil ->
        nil

      [summary, version, updated_unix] ->
        %{summary: summary, version: version, updated_unix: updated_unix}
    end)
  end

  @doc "`AMEM.SUMMARY.DROP agent_id` -> `true` if it existed."
  @spec summary_drop(conn, String.t()) :: {:ok, boolean} | {:error, Error.t()}
  def summary_drop(conn, agent_id),
    do: conn |> HotKV.command(["AMEM.SUMMARY.DROP", agent_id]) |> Reply.map(&Reply.to_bool/1)

  @doc "`AMEM.SUMMARY.LIST` -> every agent id with a stored summary."
  @spec summary_list(conn) :: {:ok, [String.t()]} | {:error, Error.t()}
  def summary_list(conn), do: HotKV.command(conn, ["AMEM.SUMMARY.LIST"])

  defp vector_args(vector), do: Enum.map(vector, &vector_arg/1)
  defp vector_arg(value) when is_float(value), do: HotKV.Numeric.format_float(value)
  defp vector_arg(value), do: value
end
