# Copyright (c) 2026 HotKV Ltd
# Licensed under the Apache License, Version 2.0. See LICENSE in the project root.

defmodule HotKV.Alerts do
  @moduledoc "`ALERTS`: operational alert dispatch (needs a server license that includes the observability feature; admin)."

  alias HotKV.{Error, Reply}

  @type conn :: HotKV.conn()

  @doc """
  `ALERTS INFO` -> `%{enabled:, flag_enabled:, webhook_url:, provider:,
  supported_providers:, min_severity:, alerts_sent:, alerts_failed:,
  alerts_dropped:, alerts_rate_limited:, alerts_deduped:, alerts_filtered:,
  alerts_queued:}` (`provider` is one of `"slack"`/`"discord"`/
  `"telegram"`/`"generic"`).
  """
  @spec info(conn) :: {:ok, map} | {:error, Error.t()}
  def info(conn), do: conn |> HotKV.command(["ALERTS", "INFO"]) |> Reply.map(&Reply.to_map/1)

  @doc """
  `ALERTS TEST [info|warning|critical] [message ...]` -> a confirmation
  string starting `"OK"` on success, or a server error if the test alert
  was rejected (severity filtered, rate-limited, deduped, or queue full).
  `message` parts, if any, are joined with spaces.
  """
  @spec test(conn, :info | :warning | :critical | nil, [String.t()]) ::
          {:ok, String.t()} | {:error, Error.t()}
  def test(conn, severity \\ nil, message_parts \\ []) do
    severity_arg = if severity, do: [Atom.to_string(severity)], else: []
    HotKV.command(conn, ["ALERTS", "TEST" | severity_arg] ++ message_parts)
  end

  @doc "`ALERTS SETURL url` -> a confirmation string. An empty `url` disables alerting."
  @spec seturl(conn, String.t()) :: {:ok, String.t()} | {:error, Error.t()}
  def seturl(conn, url), do: HotKV.command(conn, ["ALERTS", "SETURL", url])

  @doc "`ALERTS SETSEVERITY info|warning|critical` -> a confirmation string."
  @spec setseverity(conn, :info | :warning | :critical) :: {:ok, String.t()} | {:error, Error.t()}
  def setseverity(conn, severity) when severity in [:info, :warning, :critical] do
    HotKV.command(conn, ["ALERTS", "SETSEVERITY", Atom.to_string(severity)])
  end

  @doc "`ALERTS ON` -> a confirmation string. Enables alert dispatch without clearing the webhook URL."
  @spec on(conn) :: {:ok, String.t()} | {:error, Error.t()}
  def on(conn), do: HotKV.command(conn, ["ALERTS", "ON"])

  @doc "`ALERTS OFF` -> a confirmation string. Disables alert dispatch without clearing the webhook URL."
  @spec off(conn) :: {:ok, String.t()} | {:error, Error.t()}
  def off(conn), do: HotKV.command(conn, ["ALERTS", "OFF"])
end
