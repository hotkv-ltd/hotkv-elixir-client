# Copyright (c) 2026 HotKV Ltd
# Licensed under the Apache License, Version 2.0. See LICENSE in the project root.

defmodule HotKV.Channels do
  @moduledoc """
  Publishing and channel introspection on an ordinary connection:
  `PUBLISH`, `SPUBLISH` and the `PUBSUB` subcommands.

  Receiving messages (`SUBSCRIBE`, `PSUBSCRIBE`, `SSUBSCRIBE`) needs a
  dedicated connection and lives in `HotKV.PubSub`.
  """

  alias HotKV.{Error, Reply}

  @type conn :: HotKV.conn()

  @doc "`PUBLISH channel message` -> the number of clients that received the message."
  @spec publish(conn, String.t(), binary) :: {:ok, integer} | {:error, Error.t()}
  def publish(conn, channel, message), do: HotKV.command(conn, ["PUBLISH", channel, message])

  @doc "`SPUBLISH shard_channel message` -> the number of clients that received the message."
  @spec spublish(conn, String.t(), binary) :: {:ok, integer} | {:error, Error.t()}
  def spublish(conn, channel, message), do: HotKV.command(conn, ["SPUBLISH", channel, message])

  @doc "`PUBSUB CHANNELS [pattern]` -> the active channels, optionally only those matching the glob `pattern`."
  @spec channels(conn, String.t() | nil) :: {:ok, [String.t()]} | {:error, Error.t()}
  def channels(conn, pattern \\ nil),
    do: HotKV.command(conn, ["PUBSUB", "CHANNELS" | opt(pattern)])

  @doc "`PUBSUB SHARDCHANNELS [pattern]` -> the active shard channels."
  @spec shard_channels(conn, String.t() | nil) :: {:ok, [String.t()]} | {:error, Error.t()}
  def shard_channels(conn, pattern \\ nil),
    do: HotKV.command(conn, ["PUBSUB", "SHARDCHANNELS" | opt(pattern)])

  @doc "`PUBSUB NUMSUB [channel ...]` -> a map of channel to subscriber count (channel subscriptions only, not patterns)."
  @spec numsub(conn, [String.t()]) :: {:ok, %{String.t() => integer}} | {:error, Error.t()}
  def numsub(conn, channels \\ []),
    do: conn |> HotKV.command(["PUBSUB", "NUMSUB" | channels]) |> Reply.map(&to_counts/1)

  @doc "`PUBSUB SHARDNUMSUB [channel ...]` -> a map of shard channel to subscriber count."
  @spec shard_numsub(conn, [String.t()]) :: {:ok, %{String.t() => integer}} | {:error, Error.t()}
  def shard_numsub(conn, channels \\ []),
    do: conn |> HotKV.command(["PUBSUB", "SHARDNUMSUB" | channels]) |> Reply.map(&to_counts/1)

  @doc "`PUBSUB NUMPAT` -> the number of active pattern subscriptions."
  @spec numpat(conn) :: {:ok, integer} | {:error, Error.t()}
  def numpat(conn), do: HotKV.command(conn, ["PUBSUB", "NUMPAT"])

  defp opt(nil), do: []
  defp opt(pattern), do: [pattern]

  defp to_counts(reply), do: reply |> Reply.to_pairs() |> Map.new()
end
