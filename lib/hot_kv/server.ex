# Copyright (c) 2026 HotKV Ltd
# Licensed under the Apache License, Version 2.0. See LICENSE in the project root.

defmodule HotKV.Server do
  @moduledoc "Server introspection and administration commands."

  alias HotKV.{Error, Reply}

  @type conn :: HotKV.conn()

  @doc "`PING [message]` -> `\"PONG\"`, or `message` echoed back."
  @spec ping(conn, String.t() | nil) :: {:ok, String.t()} | {:error, Error.t()}
  def ping(conn, message \\ nil)
  def ping(conn, nil), do: HotKV.command(conn, ["PING"])
  def ping(conn, message), do: HotKV.command(conn, ["PING", message])

  @doc "`ECHO message` -> `message`."
  @spec echo(conn, String.t()) :: {:ok, String.t()} | {:error, Error.t()}
  def echo(conn, message), do: HotKV.command(conn, ["ECHO", message])

  @doc "`INFO [section]` -> the server's info text (parse it yourself; the format is `key:value` lines)."
  @spec info(conn, String.t() | nil) :: {:ok, String.t()} | {:error, Error.t()}
  def info(conn, section \\ nil)
  def info(conn, nil), do: HotKV.command(conn, ["INFO"])
  def info(conn, section), do: HotKV.command(conn, ["INFO", section])

  @doc "`DBSIZE` -> the number of keys in the selected database."
  @spec dbsize(conn) :: {:ok, integer} | {:error, Error.t()}
  def dbsize(conn), do: HotKV.command(conn, ["DBSIZE"])

  @doc "`FLUSHDB [ASYNC|SYNC]` -> `\"OK\"`."
  @spec flushdb(conn, :async | :sync | nil) :: {:ok, String.t()} | {:error, Error.t()}
  def flushdb(conn, mode \\ nil), do: HotKV.command(conn, ["FLUSHDB" | mode_arg(mode)])

  @doc "`FLUSHALL [ASYNC|SYNC]` -> `\"OK\"`."
  @spec flushall(conn, :async | :sync | nil) :: {:ok, String.t()} | {:error, Error.t()}
  def flushall(conn, mode \\ nil), do: HotKV.command(conn, ["FLUSHALL" | mode_arg(mode)])

  defp mode_arg(nil), do: []

  defp mode_arg(mode) when mode in [:async, :sync],
    do: [mode |> Atom.to_string() |> String.upcase()]

  @doc "`TIME` -> `{unix_seconds, microseconds}`."
  @spec time(conn) :: {:ok, {integer, integer}} | {:error, Error.t()}
  def time(conn) do
    conn
    |> HotKV.command(["TIME"])
    |> Reply.map(fn [s, us] -> {String.to_integer(s), String.to_integer(us)} end)
  end

  @doc "`CONFIG GET parameter` -> a map of every matching parameter name to its value."
  @spec config_get(conn, String.t()) :: {:ok, map} | {:error, Error.t()}
  def config_get(conn, parameter),
    do: conn |> HotKV.command(["CONFIG", "GET", parameter]) |> Reply.map(&Reply.to_map/1)

  @doc "`CONFIG SET parameter value` -> `\"OK\"`."
  @spec config_set(conn, String.t(), String.t()) :: {:ok, String.t()} | {:error, Error.t()}
  def config_set(conn, parameter, value),
    do: HotKV.command(conn, ["CONFIG", "SET", parameter, value])

  @doc "`CLIENT SETNAME name` -> `\"OK\"`."
  @spec client_setname(conn, String.t()) :: {:ok, String.t()} | {:error, Error.t()}
  def client_setname(conn, name), do: HotKV.command(conn, ["CLIENT", "SETNAME", name])

  @doc "`CLIENT GETNAME` -> the current connection's name, `\"\"` if unset."
  @spec client_getname(conn) :: {:ok, String.t()} | {:error, Error.t()}
  def client_getname(conn), do: HotKV.command(conn, ["CLIENT", "GETNAME"])

  @doc "`CLIENT ID` -> the current connection's server-assigned id."
  @spec client_id(conn) :: {:ok, integer} | {:error, Error.t()}
  def client_id(conn), do: HotKV.command(conn, ["CLIENT", "ID"])

  @doc "`SELECT index` -> `\"OK\"`. Switches the selected database for this connection."
  @spec select(conn, non_neg_integer) :: {:ok, String.t()} | {:error, Error.t()}
  def select(conn, index), do: HotKV.command(conn, ["SELECT", index])
end
