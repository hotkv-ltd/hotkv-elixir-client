# Copyright (c) 2026 HotKV Ltd
# Licensed under the Apache License, Version 2.0. See LICENSE in the project root.

defmodule HotKV.TestSupport.FakeConn do
  @moduledoc false
  # The smallest seam that lets a unit test assert a typed wrapper's exact
  # wire argument list without a live server: `HotKV.Connection.command/3`
  # (what `HotKV.command/2,3` and every typed wrapper ultimately call) is
  # just `GenServer.call(conn, {:command, iodata}, timeout)` (the caller
  # encodes the request, see `HotKV.RESP.encode/1`), so a minimal GenServer
  # that answers that one message shape stands in for a real connection,
  # with zero changes to any production code path. Every captured command
  # is decoded back from the exact bytes that would go on the wire into a
  # list of binaries (see `calls/1`/`last_call/1`; compare against
  # `wire/1` of the expected arguments) and answered with `reply` (default
  # `{:ok, "OK"}`).
  use GenServer

  @doc "Starts a `FakeConn` that answers every command with `reply`."
  def start_link(reply \\ {:ok, "OK"}) do
    GenServer.start_link(__MODULE__, %{reply: reply, calls: []})
  end

  @doc """
  Converts an expected argument list to the binaries the wire carries (what
  `calls/1` returns): `wire(["TTL", 30, 0.5])` is `["TTL", "30", "0.5"]`.
  """
  def wire(args), do: args |> HotKV.RESP.encode() |> IO.iodata_to_binary() |> decode_request()

  @doc "Every argument list sent to this fake connection so far, as wire binaries, oldest first."
  def calls(conn), do: GenServer.call(conn, :calls)

  @doc "The most recent argument list sent to this fake connection, or `nil`."
  def last_call(conn), do: conn |> calls() |> List.last()

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call({:command, iodata}, _from, state) do
    args = iodata |> IO.iodata_to_binary() |> decode_request()
    {:reply, state.reply, %{state | calls: state.calls ++ [args]}}
  end

  def handle_call(:calls, _from, state), do: {:reply, state.calls, state}

  # "*N\r\n$\len..." -> [bytes, ...]
  defp decode_request("*" <> rest) do
    {count, "\r\n" <> body} = Integer.parse(rest)
    decode_bulks(body, count, [])
  end

  defp decode_bulks(<<>>, 0, acc), do: Enum.reverse(acc)

  defp decode_bulks("$" <> rest, count, acc) when count > 0 do
    {len, "\r\n" <> body} = Integer.parse(rest)
    <<bytes::binary-size(len), "\r\n", tail::binary>> = body
    decode_bulks(tail, count - 1, [bytes | acc])
  end
end
