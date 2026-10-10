# Copyright (c) 2026 HotKV Ltd
# Licensed under the Apache License, Version 2.0. See LICENSE in the project root.

defmodule HotKV.Observe do
  @moduledoc "`OBSERVE`: server metrics (needs a server license that includes the observability feature; admin)."

  alias HotKV.{Error, Reply}

  @type conn :: HotKV.conn()

  @doc """
  `OBSERVE INFO` -> `%{uptime_seconds:, connected_clients:,
  total_commands:, used_memory_bytes:, peak_memory_bytes:,
  total_connections:, enterprise_features:}`.
  """
  @spec info(conn) :: {:ok, map} | {:error, Error.t()}
  def info(conn), do: conn |> HotKV.command(["OBSERVE", "INFO"]) |> Reply.map(&Reply.to_map/1)

  @doc """
  `OBSERVE METRICS` -> `%{uptime_seconds:, connected_clients:,
  total_commands:, total_connections:, used_memory_bytes:,
  peak_memory_bytes:, slowlog_length:, alerts_sent:, alerts_failed:,
  num_workers:}`.
  """
  @spec metrics(conn) :: {:ok, map} | {:error, Error.t()}
  def metrics(conn),
    do: conn |> HotKV.command(["OBSERVE", "METRICS"]) |> Reply.map(&Reply.to_map/1)
end
