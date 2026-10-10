# Copyright (c) 2026 HotKV Ltd
# Licensed under the Apache License, Version 2.0. See LICENSE in the project root.

defmodule HotKV.PubSub do
  @moduledoc """
  A dedicated publish/subscribe connection.

  Pub/sub uses its own connection (a subscribed connection cannot also run
  ordinary commands), so `HotKV.PubSub` is separate from `HotKV.Connection`.
  Any number of local processes can subscribe to any number of
  channels/patterns/shard channels through one `HotKV.PubSub`; each message
  is delivered to every interested subscriber as:

      {:hotkv_pubsub, pubsub_pid, :message, %{channel: channel, payload: payload}}
      {:hotkv_pubsub, pubsub_pid, :pmessage, %{pattern: pattern, channel: channel, payload: payload}}
      {:hotkv_pubsub, pubsub_pid, :smessage, %{channel: channel, payload: payload}}

  matching plain `SUBSCRIBE`/`PSUBSCRIBE`/`SSUBSCRIBE` (RESP2 arrays or, once
  `HELLO 3` is negotiated, RESP3 push frames -- both are handled the same
  way). `subscribe/3` and friends return once the server has acknowledged
  the request, so a message published right afterwards is delivered (they
  stop waiting after 5 seconds, or at once while the connection is down).
  If the underlying connection drops, every current subscription is
  re-sent automatically once it reconnects. A subscriber process that exits
  is unsubscribed automatically.

      {:ok, pubsub} = HotKV.PubSub.start_link(url: "hotkv://127.0.0.1:6379")
      :ok = HotKV.PubSub.subscribe(pubsub, ["news"])

      receive do
        {:hotkv_pubsub, ^pubsub, :message, %{channel: "news", payload: payload}} ->
          IO.puts(payload)
      end
  """

  use GenServer
  require Logger

  alias HotKV.{Error, Options, RESP, Transport}

  defstruct [
    :transport,
    :socket,
    :opts,
    :owner,
    status: :connecting,
    buffer: <<>>,
    backoff: 500,
    registry: %{channel: %{}, pattern: %{}, schannel: %{}},
    monitors: %{},
    refcounts: %{},
    # Callers blocked until the server acknowledges their (un)subscribe:
    # waiters: ref => {from, outstanding {action, kind, name} keys, timer};
    # ack_index: key => [ref] in request order.
    waiters: %{},
    ack_index: %{}
  ]

  @max_backoff 30_000
  @ack_timeout 5_000
  @ack_frames %{
    "subscribe" => {:subscribe, :channel},
    "psubscribe" => {:subscribe, :pattern},
    "ssubscribe" => {:subscribe, :schannel},
    "unsubscribe" => {:unsubscribe, :channel},
    "punsubscribe" => {:unsubscribe, :pattern},
    "sunsubscribe" => {:unsubscribe, :schannel}
  }
  @ack_types Map.keys(@ack_frames)
  @wire %{
    channel: {"SUBSCRIBE", "UNSUBSCRIBE"},
    pattern: {"PSUBSCRIBE", "PUNSUBSCRIBE"},
    schannel: {"SSUBSCRIBE", "SUNSUBSCRIBE"}
  }

  # -- public API -----------------------------------------------------

  @spec start_link(keyword) :: GenServer.on_start()
  def start_link(opts \\ []) when is_list(opts) do
    {gen_opts, conn_opts} = Keyword.split(opts, [:name])
    HotKV.Link.start_link(__MODULE__, conn_opts, gen_opts)
  end

  @doc """
  Subscribes `subscriber` (default `self()`) to `channels`. Returns once the
  server has acknowledged the subscription (so a message published right
  afterwards is delivered), after 5 seconds, or at once when the connection
  is currently down (the subscription is re-sent on reconnect).
  """
  @spec subscribe(GenServer.server(), [String.t()] | String.t(), pid) :: :ok
  def subscribe(pubsub, channels, subscriber \\ self()),
    do: GenServer.call(pubsub, {:register, :channel, List.wrap(channels), subscriber})

  @doc "Subscribes `subscriber` (default `self()`) to glob `patterns`."
  @spec psubscribe(GenServer.server(), [String.t()] | String.t(), pid) :: :ok
  def psubscribe(pubsub, patterns, subscriber \\ self()),
    do: GenServer.call(pubsub, {:register, :pattern, List.wrap(patterns), subscriber})

  @doc "Subscribes `subscriber` (default `self()`) to shard `channels`."
  @spec ssubscribe(GenServer.server(), [String.t()] | String.t(), pid) :: :ok
  def ssubscribe(pubsub, channels, subscriber \\ self()),
    do: GenServer.call(pubsub, {:register, :schannel, List.wrap(channels), subscriber})

  @doc "Unsubscribes `subscriber` from `channels` (all of its channels if omitted)."
  @spec unsubscribe(GenServer.server(), [String.t()] | String.t(), pid) :: :ok
  def unsubscribe(pubsub, channels \\ [], subscriber \\ self()),
    do: GenServer.call(pubsub, {:unregister, :channel, List.wrap(channels), subscriber})

  @doc "Unsubscribes `subscriber` from `patterns` (all of its patterns if omitted)."
  @spec punsubscribe(GenServer.server(), [String.t()] | String.t(), pid) :: :ok
  def punsubscribe(pubsub, patterns \\ [], subscriber \\ self()),
    do: GenServer.call(pubsub, {:unregister, :pattern, List.wrap(patterns), subscriber})

  @doc "Unsubscribes `subscriber` from shard `channels` (all of its shard channels if omitted)."
  @spec sunsubscribe(GenServer.server(), [String.t()] | String.t(), pid) :: :ok
  def sunsubscribe(pubsub, channels \\ [], subscriber \\ self()),
    do: GenServer.call(pubsub, {:unregister, :schannel, List.wrap(channels), subscriber})

  @doc "Returns `%{channel: [...], pattern: [...], schannel: [...]}` currently subscribed to on this connection."
  @spec subscriptions(GenServer.server()) :: %{
          channel: [String.t()],
          pattern: [String.t()],
          schannel: [String.t()]
        }
  def subscriptions(pubsub), do: GenServer.call(pubsub, :subscriptions)

  # -- GenServer callbacks ---------------------------------------------

  @impl true
  def init({:"$hotkv_owner", owner, opts}) do
    case Options.new(opts) do
      {:ok, options} ->
        Process.flag(:trap_exit, true)
        connect(%__MODULE__{opts: options, owner: owner})

      {:error, reason} ->
        {:stop, reason}
    end
  end

  defp connect(state) do
    case Transport.connect(state.opts) do
      {:ok, transport, socket, _resp3, leftover} ->
        {:ok,
         %{
           state
           | transport: transport,
             socket: socket,
             status: :connected,
             buffer: leftover,
             backoff: 500
         }}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call({:register, kind, names, subscriber}, from, state) do
    state = Enum.reduce(names, state, &add_member(&2, kind, &1, subscriber))
    wait_for_acks(state, from, kind, :subscribe, names)
  end

  def handle_call({:unregister, kind, [], subscriber}, from, state) do
    names = names_for(state, kind, subscriber)
    {state, to_unsub} = do_unregister(state, kind, names, subscriber)
    wait_for_acks(state, from, kind, :unsubscribe, to_unsub)
  end

  def handle_call({:unregister, kind, names, subscriber}, from, state) do
    {state, to_unsub} = do_unregister(state, kind, names, subscriber)
    wait_for_acks(state, from, kind, :unsubscribe, to_unsub)
  end

  def handle_call(:subscriptions, _from, state) do
    result = Map.new(state.registry, fn {kind, map} -> {kind, Map.keys(map)} end)
    {:reply, result, state}
  end

  @impl true
  # The process that started this one (see HotKV.Link): its exit stops us;
  # any other exit message (a closed socket port) is ignored.
  def handle_info({:EXIT, owner, reason}, %{owner: owner} = state), do: {:stop, reason, state}
  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  def handle_info({kind, socket, data}, %{socket: socket} = state) when kind in [:tcp, :ssl] do
    state = drain(state, state.buffer <> data)

    case Transport.arm(state.transport, state.socket) do
      :ok -> {:noreply, state}
      {:error, reason} -> {:noreply, disconnect(state, reason)}
    end
  end

  def handle_info({kind, socket}, %{socket: socket} = state)
      when kind in [:tcp_closed, :ssl_closed] do
    {:noreply, disconnect(state, Error.connection("connection closed by peer"))}
  end

  def handle_info({kind, socket, reason}, %{socket: socket} = state)
      when kind in [:tcp_error, :ssl_error] do
    {:noreply, disconnect(state, Error.connection("socket error: #{inspect(reason)}"))}
  end

  def handle_info(:reconnect, state) do
    case Transport.connect(state.opts) do
      {:ok, transport, socket, _resp3, leftover} ->
        state = %{
          state
          | transport: transport,
            socket: socket,
            status: :connected,
            buffer: leftover,
            backoff: 500
        }

        {:noreply, resubscribe_all(state)}

      {:error, _reason} ->
        backoff = min(state.backoff * 2, @max_backoff)
        Process.send_after(self(), :reconnect, backoff)
        {:noreply, %{state | backoff: backoff}}
    end
  end

  def handle_info({:ack_timeout, ref}, state) do
    # The server never confirmed (or the confirmation was lost): do not hold
    # the caller any longer; the subscription state is tracked locally.
    {:noreply, finish_waiter(state, ref)}
  end

  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    state =
      Enum.reduce([:channel, :pattern, :schannel], state, fn kind, st ->
        {st, to_unsub} = do_unregister(st, kind, names_for(st, kind, pid), pid)
        send_wire(st, kind, :unsubscribe, to_unsub)
        st
      end)

    {:noreply,
     %{
       state
       | monitors: Map.delete(state.monitors, pid),
         refcounts: Map.delete(state.refcounts, pid)
     }}
  end

  def handle_info({kind, _socket, _data}, state) when kind in [:tcp, :ssl], do: {:noreply, state}

  def handle_info({kind, _socket}, state) when kind in [:tcp_closed, :ssl_closed],
    do: {:noreply, state}

  @impl true
  def format_status(_reason, [_pdict, state]), do: redact_state(state)

  defp redact_state(%__MODULE__{opts: opts} = state), do: %{state | opts: Options.redact(opts)}
  defp redact_state(other), do: other

  @impl true
  def terminate(_reason, %{socket: nil}), do: :ok
  def terminate(_reason, state), do: Transport.close(state.transport, state.socket)

  # -- subscriber registry ----------------------------------------------

  defp names_for(state, kind, subscriber) do
    state.registry[kind]
    |> Enum.filter(fn {_name, set} -> MapSet.member?(set, subscriber) end)
    |> Enum.map(fn {name, _set} -> name end)
  end

  defp add_member(state, kind, name, subscriber) do
    current = Map.get(state.registry[kind], name, MapSet.new())

    if MapSet.member?(current, subscriber) do
      state
    else
      state = put_in(state.registry[kind][name], MapSet.put(current, subscriber))
      monitor_add(state, subscriber)
    end
  end

  defp do_unregister(state, kind, names, subscriber) do
    {to_unsub, state} =
      Enum.reduce(names, {[], state}, fn name, {acc, st} ->
        current = Map.get(st.registry[kind], name, MapSet.new())

        if MapSet.member?(current, subscriber) do
          updated = MapSet.delete(current, subscriber)

          registry_kind =
            if MapSet.size(updated) == 0,
              do: Map.delete(st.registry[kind], name),
              else: Map.put(st.registry[kind], name, updated)

          st = put_in(st.registry[kind], registry_kind)
          st = monitor_remove(st, subscriber)
          acc = if MapSet.size(updated) == 0, do: [name | acc], else: acc
          {acc, st}
        else
          {acc, st}
        end
      end)

    {state, Enum.reverse(to_unsub)}
  end

  defp monitor_add(state, pid) do
    count = Map.get(state.refcounts, pid, 0)
    state = %{state | refcounts: Map.put(state.refcounts, pid, count + 1)}

    if count == 0 do
      %{state | monitors: Map.put(state.monitors, pid, Process.monitor(pid))}
    else
      state
    end
  end

  defp monitor_remove(state, pid) do
    case Map.get(state.refcounts, pid, 0) do
      n when n <= 1 ->
        case Map.pop(state.monitors, pid) do
          {nil, monitors} ->
            %{state | monitors: monitors, refcounts: Map.delete(state.refcounts, pid)}

          {ref, monitors} ->
            Process.demonitor(ref, [:flush])
            %{state | monitors: monitors, refcounts: Map.delete(state.refcounts, pid)}
        end

      n ->
        %{state | refcounts: Map.put(state.refcounts, pid, n - 1)}
    end
  end

  defp resubscribe_all(state) do
    Enum.each([:channel, :pattern, :schannel], fn kind ->
      send_wire(state, kind, :subscribe, Map.keys(state.registry[kind]))
    end)

    state
  end

  # -- wire I/O -----------------------------------------------------------

  # Sends the (un)subscribe request and, when it was written, parks the
  # caller until the server has acknowledged every name (or `@ack_timeout`).
  defp wait_for_acks(state, _from, _kind, _action, []), do: {:reply, :ok, state}

  defp wait_for_acks(%{status: :disconnected} = state, _from, _kind, _action, _names),
    do: {:reply, :ok, state}

  defp wait_for_acks(state, from, kind, action, names) do
    case send_wire(state, kind, action, names) do
      :ok ->
        ref = make_ref()
        keys = MapSet.new(names, &{action, kind, &1})
        timer = Process.send_after(self(), {:ack_timeout, ref}, @ack_timeout)

        index =
          Enum.reduce(keys, state.ack_index, fn key, acc ->
            Map.update(acc, key, [ref], &(&1 ++ [ref]))
          end)

        {:noreply,
         %{state | waiters: Map.put(state.waiters, ref, {from, keys, timer}), ack_index: index}}

      :error ->
        {:reply, :ok, state}
    end
  end

  defp ack(state, action, kind, name) do
    key = {action, kind, name}

    case Map.get(state.ack_index, key, []) do
      [] ->
        state

      [ref | rest] ->
        index =
          if rest == [],
            do: Map.delete(state.ack_index, key),
            else: Map.put(state.ack_index, key, rest)

        state = %{state | ack_index: index}

        case Map.fetch(state.waiters, ref) do
          {:ok, {from, keys, timer}} ->
            keys = MapSet.delete(keys, key)

            if MapSet.size(keys) == 0 do
              finish_waiter(state, ref)
            else
              %{state | waiters: Map.put(state.waiters, ref, {from, keys, timer})}
            end

          # a waiter that already timed out: the ack belongs to the next one
          :error ->
            ack(state, action, kind, name)
        end
    end
  end

  defp finish_waiter(state, ref) do
    case Map.pop(state.waiters, ref) do
      {nil, _} ->
        state

      {{from, _keys, timer}, waiters} ->
        Process.cancel_timer(timer)
        GenServer.reply(from, :ok)
        %{state | waiters: waiters}
    end
  end

  defp release_all_waiters(state) do
    state.waiters
    |> Map.keys()
    |> Enum.reduce(state, &finish_waiter(&2, &1))
    |> Map.put(:ack_index, %{})
  end

  defp send_wire(_state, _kind, _action, []), do: :ok
  defp send_wire(%{status: :disconnected}, _kind, _action, _names), do: :ok

  defp send_wire(state, kind, action, names) do
    {sub_cmd, unsub_cmd} = @wire[kind]
    cmd = if action == :subscribe, do: sub_cmd, else: unsub_cmd

    case Transport.send(state.transport, state.socket, RESP.encode([cmd | names])) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.debug("HotKV.PubSub failed to send #{cmd}: #{inspect(reason)}")
        :error
    end
  end

  defp drain(state, buffer) do
    case RESP.decode(buffer) do
      {:ok, value, rest} -> state |> handle_frame(value) |> drain(rest)
      :incomplete -> %{state | buffer: buffer}
      {:error, {:protocol, reason}} -> disconnect(state, Error.protocol(reason))
    end
  end

  defp handle_frame(state, {:push, elements}), do: handle_elements(state, elements)
  defp handle_frame(state, elements) when is_list(elements), do: handle_elements(state, elements)
  defp handle_frame(state, _other), do: state

  defp handle_elements(state, ["message", channel, payload]) do
    deliver(state, :channel, channel, %{channel: channel, payload: payload}, :message)
  end

  defp handle_elements(state, ["pmessage", pattern, channel, payload]) do
    deliver(
      state,
      :pattern,
      pattern,
      %{pattern: pattern, channel: channel, payload: payload},
      :pmessage
    )
  end

  defp handle_elements(state, ["smessage", channel, payload]) do
    deliver(state, :schannel, channel, %{channel: channel, payload: payload}, :smessage)
  end

  defp handle_elements(state, [type, name | _rest]) when type in @ack_types do
    {action, kind} = Map.fetch!(@ack_frames, type)
    ack(state, action, kind, name)
  end

  defp handle_elements(state, other) do
    Logger.debug("HotKV.PubSub unrecognized frame: #{inspect(other)}")
    state
  end

  defp deliver(state, kind, name, payload, event) do
    state.registry[kind]
    |> Map.get(name, MapSet.new())
    |> Enum.each(fn pid -> Kernel.send(pid, {:hotkv_pubsub, self(), event, payload}) end)

    state
  end

  # -- disconnect handling -----------------------------------------------

  defp disconnect(%{status: :disconnected} = state, _reason), do: state

  defp disconnect(state, _reason) do
    if state.socket, do: Transport.close(state.transport, state.socket)
    Process.send_after(self(), :reconnect, state.backoff)
    # Callers waiting for an acknowledgement are released: the subscription is
    # recorded locally and is re-sent on reconnect.
    state = release_all_waiters(state)
    %{state | status: :disconnected, socket: nil, buffer: <<>>}
  end
end
