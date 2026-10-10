# Copyright (c) 2026 HotKV Ltd
# Licensed under the Apache License, Version 2.0. See LICENSE in the project root.

defmodule HotKV.Pool do
  @moduledoc """
  A small round-robin pool of `HotKV.Connection` processes, for concurrent
  callers that would otherwise queue behind a single connection's socket.

      {:ok, pool} = HotKV.Pool.start_link(url: "hotkv://127.0.0.1:6379", size: 10)
      HotKV.command(pool, ["PING"])

  Anywhere in this library that takes a connection (`HotKV.command/3`,
  `HotKV.pipeline/3`, the typed wrapper modules, ...) also accepts a
  `HotKV.Pool.t()` returned from `start_link/1`: it checks out the next
  connection and uses it for that one call. `HotKV.transaction/3` instead
  checks out a single connection once and keeps it for the whole
  transaction, since `MULTI`/`EXEC` only make sense on one connection.

  A connection that crashes is transparently restarted, keeping the pool at
  its configured `:size`.

  ## Under a supervisor

  `{HotKV.Pool, opts}` is a valid child spec. Give it a `:name`, and use
  `handle/1` to get the value the rest of the library accepts:

      children = [{HotKV.Pool, name: MyApp.Pool, url: "hotkv://127.0.0.1:6379", size: 10}]
      # ... after the supervisor started:
      pool = HotKV.Pool.handle(MyApp.Pool)
      HotKV.command(pool, ["PING"])
  """

  use GenServer

  alias HotKV.{Connection, Error}

  defstruct [:pid]

  @type t :: %__MODULE__{pid: GenServer.server()}

  @default_size 5

  @doc """
  Starts a pool. Accepts everything `HotKV.start_link/1` does (`:url`,
  `:host`, `:port`, TLS options, ...) plus `:size` (default #{@default_size})
  and `:name` to register the pool process itself.
  """
  @spec start_link(keyword) :: {:ok, t} | {:error, term}
  def start_link(opts \\ []) when is_list(opts) do
    {pool_opts, conn_opts} = Keyword.split(opts, [:size, :name])
    size = Keyword.get(pool_opts, :size, @default_size)
    gen_opts = Keyword.take(pool_opts, [:name])

    case HotKV.Link.start_link(__MODULE__, {size, conn_opts}, gen_opts) do
      {:ok, pid} -> {:ok, %__MODULE__{pid: pid}}
      {:error, _} = error -> error
    end
  end

  @doc false
  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :name, __MODULE__),
      start: {__MODULE__, :start_supervised, [opts]},
      type: :worker
    }
  end

  # A supervisor needs {:ok, pid}, not the %HotKV.Pool{} handle.
  @doc false
  def start_supervised(opts) do
    case start_link(opts) do
      {:ok, %__MODULE__{pid: pid}} -> {:ok, pid}
      {:error, _} = error -> error
    end
  end

  @doc """
  The pool handle for a pool started under a supervisor (`{HotKV.Pool,
  name: MyApp.Pool, ...}`), given its registered name or pid.
  """
  @spec handle(GenServer.server()) :: t
  def handle(name_or_pid), do: %__MODULE__{pid: name_or_pid}

  @doc "Checks out the next connection in round-robin order."
  @spec checkout(t) :: {:ok, GenServer.server()} | {:error, Error.t()}
  def checkout(%__MODULE__{pid: server}) do
    GenServer.call(server, :checkout)
  catch
    :exit, _ -> {:error, Error.connection("pool process is not alive")}
  end

  @doc "True if at least one connection in the pool currently has a live socket."
  @spec any_connected?(t) :: boolean
  def any_connected?(%__MODULE__{pid: pid}), do: GenServer.call(pid, :any_connected?)

  @doc "Returns every connection currently in the pool, for example to run `HotKV.pipeline/3` against each."
  @spec members(t) :: [GenServer.server()]
  def members(%__MODULE__{pid: pid}), do: GenServer.call(pid, :members)

  @doc "Stops the pool and every connection in it."
  @spec stop(t) :: :ok
  def stop(%__MODULE__{pid: pid}), do: GenServer.stop(pid)

  # -- GenServer callbacks ---------------------------------------------

  @impl true
  def init({:"$hotkv_owner", owner, {size, conn_opts}}) when is_integer(size) and size > 0 do
    Process.flag(:trap_exit, true)

    case start_members(size, conn_opts, []) do
      {:ok, conns} ->
        {:ok,
         %{conns: List.to_tuple(conns), size: size, index: 0, conn_opts: conn_opts, owner: owner}}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  defp start_members(0, _conn_opts, acc), do: {:ok, Enum.reverse(acc)}

  defp start_members(n, conn_opts, acc) do
    case start_member(conn_opts) do
      {:ok, pid} ->
        start_members(n - 1, conn_opts, [pid | acc])

      {:error, _} = error ->
        Enum.each(acc, &GenServer.stop/1)
        error
    end
  end

  defp start_member(conn_opts), do: Connection.start_link(Keyword.delete(conn_opts, :name))

  @restart_delay 1_000

  @impl true
  def format_status(_reason, [_pdict, state]) do
    case state do
      %{conn_opts: conn_opts} -> %{state | conn_opts: HotKV.Options.redact(conn_opts)}
      other -> other
    end
  end

  @impl true
  def handle_call(:checkout, _from, state) do
    pid = elem(state.conns, state.index)
    {:reply, {:ok, pid}, %{state | index: rem(state.index + 1, state.size)}}
  end

  def handle_call(:any_connected?, _from, state) do
    result =
      state.conns
      |> Tuple.to_list()
      |> Enum.any?(&(Process.alive?(&1) and Connection.connected?(&1)))

    {:reply, result, state}
  end

  def handle_call(:members, _from, state) do
    {:reply, Tuple.to_list(state.conns), state}
  end

  @impl true
  def handle_info({:EXIT, owner, reason}, %{owner: owner} = state), do: {:stop, reason, state}

  def handle_info({:EXIT, pid, _reason}, state) do
    case find_index(state.conns, pid) do
      nil ->
        {:noreply, state}

      index ->
        {:noreply, restart_member(state, index)}
    end
  end

  def handle_info({:restart, index}, state), do: {:noreply, restart_member(state, index)}

  # Replaces the member at `index`. When the server is unreachable the dead
  # pid stays in its slot (calls on it return a :connection error) and the
  # restart is retried, so one outage does not take the pool down.
  defp restart_member(state, index) do
    case start_member(state.conn_opts) do
      {:ok, new_pid} ->
        %{state | conns: put_elem(state.conns, index, new_pid)}

      {:error, _} ->
        Process.send_after(self(), {:restart, index}, @restart_delay)
        state
    end
  end

  defp find_index(tuple, pid) do
    tuple
    |> Tuple.to_list()
    |> Enum.find_index(&(&1 == pid))
  end
end
