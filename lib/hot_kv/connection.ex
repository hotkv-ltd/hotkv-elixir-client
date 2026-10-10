# Copyright (c) 2026 HotKV Ltd
# Licensed under the Apache License, Version 2.0. See LICENSE in the project root.

defmodule HotKV.Connection do
  @moduledoc """
  A single pipelined connection to a HotKV server.

  `HotKV.Connection` owns one TCP/TLS socket and a FIFO queue of in-flight
  requests: every call to `command/3` or `pipeline/3` writes its request(s)
  to the socket immediately and appends to the queue, so many callers can
  have requests in flight on the same socket at once (pipelining) while
  still getting back exactly the reply that matches their own request, in
  order, RESP guarantees.

  Most applications use this through `HotKV.start_link/1` and the `HotKV`
  module's functions rather than calling this module directly.
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
    resp3: false,
    buffer: <<>>,
    queue: :queue.new(),
    batches: %{},
    backoff: 500
  ]

  @max_backoff 30_000
  @fallback_timeout 5_000
  @timeout_table :hotkv_connection_timeouts

  @doc false
  # Name of the ETS table `HotKV.Application` owns; it maps a connection pid
  # to its `:command_timeout`, so a call that passes no explicit `:timeout`
  # can honor the connection's own default without an extra round trip.
  def timeout_table, do: @timeout_table

  @doc """
  The default per-command timeout (the connection's `:command_timeout`
  option) of `conn`, or 5000 ms when `conn` is not a locally registered
  `HotKV.Connection`.
  """
  @spec default_timeout(GenServer.server()) :: timeout
  def default_timeout(conn) do
    with pid when is_pid(pid) <- GenServer.whereis(conn),
         [{^pid, timeout}] <- :ets.lookup(@timeout_table, pid) do
      timeout
    else
      _ -> @fallback_timeout
    end
  rescue
    ArgumentError -> @fallback_timeout
  end

  # -- public API -----------------------------------------------------

  @doc """
  Starts a connection process. `opts` is everything `HotKV.Options.new/1`
  accepts, plus `:name` to register the process (any GenServer name).
  """
  @spec start_link(keyword) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    {gen_opts, conn_opts} = Keyword.split(opts, [:name])
    HotKV.Link.start_link(__MODULE__, conn_opts, gen_opts)
  end

  @doc """
  Sends one command and returns its reply. `timeout` is a number of
  milliseconds, `:infinity`, or `:default` (the connection's
  `:command_timeout`).

  Raises `ArgumentError` if an argument has no wire form (see
  `HotKV.RESP.encode/1`). The request is encoded here, in the caller, so a
  bad argument never reaches (or crashes) the shared connection process.
  """
  @spec command(GenServer.server(), [term], timeout | :default) ::
          {:ok, term} | {:error, Error.t()}
  def command(conn, args, timeout \\ :default) do
    safe_call(conn, {:command, RESP.encode(args)}, resolve_timeout(conn, timeout))
  end

  @doc """
  Sends every command in `commands` in one batch and returns their replies,
  in order, as a single `{:ok, list}` (each element itself `{:ok, term} |
  {:error, Error.t()}`) unless the connection itself failed.
  """
  @spec pipeline(GenServer.server(), [[term]], timeout | :default) ::
          {:ok, [{:ok, term} | {:error, Error.t()}]} | {:error, Error.t()}
  def pipeline(conn, commands, timeout \\ :default)

  # An empty batch has nothing to send and nothing to wait for.
  def pipeline(_conn, [], _timeout), do: {:ok, []}

  def pipeline(conn, commands, timeout) when is_list(commands) do
    safe_call(
      conn,
      {:pipeline, Enum.map(commands, &RESP.encode/1)},
      resolve_timeout(conn, timeout)
    )
  end

  defp resolve_timeout(conn, :default), do: default_timeout(conn)
  defp resolve_timeout(_conn, timeout), do: timeout

  @doc "True if the connection currently has a live socket."
  @spec connected?(GenServer.server()) :: boolean
  def connected?(conn), do: GenServer.call(conn, :connected?)

  @doc "True if the connection negotiated RESP3 (`HELLO 3`) with the server."
  @spec resp3?(GenServer.server()) :: boolean
  def resp3?(conn), do: GenServer.call(conn, :resp3?)

  defp safe_call(conn, message, timeout) do
    GenServer.call(conn, message, timeout)
  catch
    :exit, {:timeout, _} -> {:error, Error.timeout()}
    :exit, {:noproc, _} -> {:error, Error.connection("connection process is not alive")}
    :exit, {:normal, _} -> {:error, Error.connection("connection process stopped")}
    :exit, reason -> {:error, Error.connection("connection exited: #{inspect(reason)}")}
  end

  # -- GenServer callbacks ---------------------------------------------

  @impl true
  def init({:"$hotkv_owner", owner, opts}) do
    case Options.new(opts) do
      {:ok, options} ->
        Process.flag(:trap_exit, true)
        register_timeout(options)
        connect(%__MODULE__{opts: options, owner: owner})

      {:error, reason} ->
        {:stop, reason}
    end
  end

  defp connect(state) do
    case Transport.connect(state.opts) do
      {:ok, transport, socket, resp3, leftover} ->
        state = %{
          state
          | transport: transport,
            socket: socket,
            status: :connected,
            resp3: resp3,
            buffer: leftover,
            backoff: 500
        }

        {:ok, state}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call(_msg, _from, %{status: :disconnected} = state) do
    {:reply, {:error, Error.connection("connection is down, reconnecting")}, state}
  end

  def handle_call({:command, iodata}, from, state) do
    case Transport.send(state.transport, state.socket, iodata) do
      :ok ->
        {:noreply, %{state | queue: :queue.in({:single, from}, state.queue)}}

      {:error, reason} ->
        {:reply, {:error, reason}, disconnect(state, reason)}
    end
  end

  def handle_call({:pipeline, iodata}, from, state) do
    n = length(iodata)

    case Transport.send(state.transport, state.socket, iodata) do
      :ok ->
        ref = make_ref()
        entries = List.duplicate({:batch, ref}, n)
        queue = Enum.reduce(entries, state.queue, &:queue.in/2)
        batches = Map.put(state.batches, ref, %{from: from, remaining: n, acc: []})
        {:noreply, %{state | queue: queue, batches: batches}}

      {:error, reason} ->
        {:reply, {:error, reason}, disconnect(state, reason)}
    end
  end

  def handle_call(:connected?, _from, state), do: {:reply, state.status == :connected, state}
  def handle_call(:resp3?, _from, state), do: {:reply, state.resp3, state}

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
      {:ok, transport, socket, resp3, leftover} ->
        Logger.debug("HotKV.Connection reconnected")

        {:noreply,
         %{
           state
           | transport: transport,
             socket: socket,
             status: :connected,
             resp3: resp3,
             buffer: leftover,
             backoff: 500
         }}

      {:error, _reason} ->
        backoff = min(state.backoff * 2, @max_backoff)
        Process.send_after(self(), :reconnect, backoff)
        {:noreply, %{state | backoff: backoff}}
    end
  end

  # Ignore stray messages from an old, already-replaced socket.
  def handle_info({kind, _socket, _data}, state) when kind in [:tcp, :ssl], do: {:noreply, state}

  def handle_info({kind, _socket}, state) when kind in [:tcp_closed, :ssl_closed],
    do: {:noreply, state}

  @impl true
  def format_status(_reason, [_pdict, state]), do: redact_state(state)

  defp redact_state(%__MODULE__{opts: opts} = state), do: %{state | opts: Options.redact(opts)}
  defp redact_state(other), do: other

  @impl true
  def terminate(_reason, state) do
    unregister_timeout()
    if state.socket, do: Transport.close(state.transport, state.socket)
    :ok
  end

  defp register_timeout(%Options{command_timeout: timeout}) do
    :ets.insert(@timeout_table, {self(), timeout})
  rescue
    # The :hotkv application (which owns the table) is not running.
    ArgumentError -> :ok
  end

  defp unregister_timeout do
    :ets.delete(@timeout_table, self())
  rescue
    ArgumentError -> :ok
  end

  # -- reply draining ---------------------------------------------------

  defp drain(state, buffer) do
    case RESP.decode(buffer) do
      {:ok, value, rest} ->
        state |> dispatch(value) |> drain(rest)

      :incomplete ->
        %{state | buffer: buffer}

      {:error, {:protocol, reason}} ->
        disconnect(state, Error.protocol(reason))
    end
  end

  defp dispatch(state, {:push, _elements} = push) do
    # Unsolicited RESP3 push frame on a regular command connection (for
    # example a keyspace invalidation message). HotKV.PubSub handles the
    # normal SUBSCRIBE/PSUBSCRIBE/SSUBSCRIBE case on its own connection;
    # here there is no per-command waiter to deliver it to, so it is
    # logged and dropped rather than misapplied to an unrelated caller.
    Logger.debug("HotKV.Connection ignoring unsolicited push frame: #{inspect(push)}")
    state
  end

  defp dispatch(state, {:resp_error, message}) do
    reply(state, build_error(message))
  end

  defp dispatch(state, value) do
    reply(state, {:ok, value})
  end

  defp build_error(<<"MOVED ", _::binary>> = message),
    do: {:error, Error.cluster_redirect(message)}

  defp build_error(<<"ASK ", _::binary>> = message), do: {:error, Error.cluster_redirect(message)}
  defp build_error(message), do: {:error, Error.server(message)}

  defp reply(state, reply_value) do
    case :queue.out(state.queue) do
      {{:value, {:single, from}}, rest} ->
        GenServer.reply(from, reply_value)
        %{state | queue: rest}

      {{:value, {:batch, ref}}, rest} ->
        finish_batch_item(%{state | queue: rest}, ref, reply_value)

      {:empty, _} ->
        Logger.debug(
          "HotKV.Connection received a reply with nothing pending: #{inspect(reply_value)}"
        )

        state
    end
  end

  defp finish_batch_item(state, ref, reply_value) do
    case Map.fetch(state.batches, ref) do
      {:ok, %{from: from, remaining: 1, acc: acc}} ->
        GenServer.reply(from, {:ok, Enum.reverse([reply_value | acc])})
        %{state | batches: Map.delete(state.batches, ref)}

      {:ok, %{remaining: n, acc: acc} = batch} ->
        %{
          state
          | batches:
              Map.put(state.batches, ref, %{batch | remaining: n - 1, acc: [reply_value | acc]})
        }

      :error ->
        state
    end
  end

  # -- disconnect handling -----------------------------------------------

  defp disconnect(%{status: :disconnected} = state, _reason), do: state

  defp disconnect(state, reason) do
    error = if match?(%Error{}, reason), do: reason, else: Error.connection(inspect(reason))
    if state.socket, do: Transport.close(state.transport, state.socket)

    fail_all_pending(state, error)

    Process.send_after(self(), :reconnect, state.backoff)

    %{
      state
      | status: :disconnected,
        socket: nil,
        buffer: <<>>,
        queue: :queue.new(),
        batches: %{}
    }
  end

  defp fail_all_pending(state, error) do
    state.queue
    |> :queue.to_list()
    |> Enum.each(fn
      {:single, from} -> GenServer.reply(from, {:error, error})
      {:batch, _ref} -> :ok
    end)

    Enum.each(state.batches, fn {_ref, %{from: from}} ->
      GenServer.reply(from, {:error, error})
    end)
  end
end
