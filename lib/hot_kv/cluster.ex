# Copyright (c) 2026 HotKV Ltd
# Licensed under the Apache License, Version 2.0. See LICENSE in the project root.

defmodule HotKV.Cluster do
  @moduledoc """
  A cluster-aware client: builds a slot map from `CLUSTER SLOTS`, routes
  each command to the node that owns its key's slot (CRC16, with
  `{hash tag}` support via `HotKV.CRC16`), and follows `MOVED` (refreshing
  the slot map) and `ASK` (sending `ASKING` on the target node first)
  redirects, up to `:max_redirects` hops.

      {:ok, cluster} = HotKV.Cluster.start_link(seeds: ["10.0.0.1:6379", "10.0.0.2:6379"])
      HotKV.Cluster.command(cluster, ["GET", "foo"])

  The command's routing key is taken from `args`'s second element (the
  common position: `GET key`, `SET key value`, `HSET key field value`,
  ...); pass `key:` in `opts` to override it for a command shaped
  differently, or when the command touches no key at all (routed to any
  currently-known node).

  Routing itself (looking up or refreshing the slot map) is a fast,
  in-memory call to this process; the actual command is then sent directly
  to the target node's own `HotKV.Connection`, so concurrent callers are
  not serialized through this process.
  """

  use GenServer

  alias HotKV.{Connection, CRC16, Error}

  defstruct [:base_opts, seeds: [], ranges: [], nodes: %{}]

  @type addr :: {String.t(), pos_integer}

  @default_max_redirects 5

  # -- public API -----------------------------------------------------

  @doc """
  Starts a cluster client. `opts` accepts `:seeds` (a list of `"host:port"`
  strings) or `:urls` (a list of `hotkv://host:port` connection strings) to
  discover the cluster from; everything else (`:username`, `:password`,
  `:tls`, `:tls_opts`, ...) is applied uniformly to every node connection,
  the same as `HotKV.start_link/1`. Falls back to a single seed built from
  `:host`/`:port` (or `:url`) if neither `:seeds` nor `:urls` is given.
  """
  @spec start_link(keyword) :: GenServer.on_start()
  def start_link(opts \\ []) when is_list(opts) do
    {gen_opts, opts} = Keyword.split(opts, [:name])
    {seed_specs, opts} = Keyword.pop(opts, :seeds)
    {urls, opts} = Keyword.pop(opts, :urls)

    with {:ok, seeds} <- resolve_seeds(seed_specs, urls, opts) do
      HotKV.Link.start_link(__MODULE__, {opts, seeds}, gen_opts)
    end
  end

  defp resolve_seeds(seed_specs, _urls, _opts) when is_list(seed_specs) do
    {:ok, Enum.map(seed_specs, &parse_host_port/1)}
  end

  defp resolve_seeds(_seed_specs, urls, _opts) when is_list(urls) do
    Enum.reduce_while(urls, {:ok, []}, fn url, {:ok, acc} ->
      case HotKV.URL.parse(url) do
        {:ok, opts} ->
          {:cont, {:ok, [{Keyword.fetch!(opts, :host), Keyword.fetch!(opts, :port)} | acc]}}

        {:error, _} = err ->
          {:halt, err}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      err -> err
    end
  end

  defp resolve_seeds(_seed_specs, _urls, opts) do
    {:ok, [{Keyword.get(opts, :host, "127.0.0.1"), Keyword.get(opts, :port, 6379)}]}
  end

  defp parse_host_port(spec) do
    case String.split(spec, ":") do
      [host] ->
        {host, 6379}

      parts ->
        {port_str, host_parts} = List.pop_at(parts, -1)
        {Enum.join(host_parts, ":"), String.to_integer(port_str)}
    end
  end

  @doc "Sends `args`, routed by key, following `MOVED`/`ASK` redirects."
  @spec command(GenServer.server(), [term], keyword) :: {:ok, term} | {:error, Error.t()}
  def command(cluster, args, opts \\ []) when is_list(args) do
    key = Keyword.get(opts, :key, extract_key(args))
    timeout = Keyword.get(opts, :timeout, :default)
    max_redirects = Keyword.get(opts, :max_redirects, @default_max_redirects)
    route_and_send(cluster, args, key, timeout, max_redirects)
  end

  @doc "Like `command/3`, but returns the value directly and raises on failure."
  @spec command!(GenServer.server(), [term], keyword) :: term
  def command!(cluster, args, opts \\ []), do: cluster |> command(args, opts) |> HotKV.bang!()

  @doc "Forces a `CLUSTER SLOTS` refresh."
  @spec refresh_slots(GenServer.server()) :: :ok | {:error, Error.t()}
  def refresh_slots(cluster), do: GenServer.call(cluster, :refresh_slots)

  @doc "Returns the current slot map as a list of `%{start:, end:, master:, replicas:}` ranges."
  @spec slot_map(GenServer.server()) :: [map]
  def slot_map(cluster), do: GenServer.call(cluster, :slot_map)

  defp extract_key([_cmd, key | _rest]) when is_binary(key), do: key
  defp extract_key(_args), do: nil

  # -- redirect-following (runs in the caller, not this GenServer) ------

  defp route_and_send(_cluster, _args, _key, _timeout, 0) do
    {:error,
     %Error{
       kind: :cluster_redirect,
       message: "too many cluster redirects (MOVED/ASK), see the :max_redirects option",
       prefix: "MOVED"
     }}
  end

  defp route_and_send(cluster, args, key, timeout, redirects_left) do
    slot = CRC16.key_slot(key || "")

    case GenServer.call(cluster, {:route, slot}) do
      {:ok, pid} ->
        follow(
          Connection.command(pid, args, timeout),
          cluster,
          args,
          key,
          timeout,
          redirects_left
        )

      {:error, _} = err ->
        err
    end
  end

  defp send_asking(cluster, args, addr, key, timeout, redirects_left) do
    case GenServer.call(cluster, {:node_pid, addr}) do
      {:ok, pid} ->
        result =
          with {:ok, _} <- Connection.command(pid, ["ASKING"], timeout) do
            Connection.command(pid, args, timeout)
          end

        follow(result, cluster, args, key, timeout, redirects_left)

      {:error, _} = err ->
        err
    end
  end

  defp follow(
         {:error, %Error{kind: :cluster_redirect, redirect: %{type: :moved}}},
         cluster,
         args,
         key,
         timeout,
         left
       ) do
    _ = GenServer.call(cluster, :refresh_slots)
    route_and_send(cluster, args, key, timeout, left - 1)
  end

  defp follow(
         {:error, %Error{kind: :cluster_redirect, redirect: %{type: :ask, host: h, port: p}}},
         cluster,
         args,
         key,
         timeout,
         left
       ) do
    send_asking(cluster, args, {h, p}, key, timeout, left - 1)
  end

  defp follow(result, _cluster, _args, _key, _timeout, _left), do: result

  # -- GenServer callbacks ---------------------------------------------

  @impl true
  def init({:"$hotkv_owner", _owner, {base_opts, seeds}}) do
    state = %__MODULE__{base_opts: base_opts, seeds: seeds}

    state =
      Enum.reduce(seeds, state, fn addr, st ->
        {_result, st} = ensure_node(st, addr)
        st
      end)

    case do_refresh_slots(state) do
      {:ok, state} -> {:ok, state}
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def format_status(_reason, [_pdict, state]) do
    case state do
      %__MODULE__{base_opts: base_opts} ->
        %{state | base_opts: HotKV.Options.redact(base_opts)}

      other ->
        other
    end
  end

  @impl true
  def handle_call({:route, slot}, _from, state) do
    case find_range(state.ranges, slot) do
      %{master: addr} ->
        {result, state} = ensure_node(state, addr)
        {:reply, result, state}

      nil ->
        {:reply, {:error, Error.connection("no cluster node known for slot #{slot}")}, state}
    end
  end

  def handle_call({:node_pid, addr}, _from, state) do
    {result, state} = ensure_node(state, addr)
    {:reply, result, state}
  end

  def handle_call(:refresh_slots, _from, state) do
    case do_refresh_slots(state) do
      {:ok, state} -> {:reply, :ok, state}
      {:error, _} = err -> {:reply, err, state}
    end
  end

  def handle_call(:slot_map, _from, state), do: {:reply, state.ranges, state}

  # -- slot map -----------------------------------------------------------

  defp find_range(ranges, slot) do
    Enum.find(ranges, fn %{start: s, end: e} -> slot >= s and slot <= e end)
  end

  defp do_refresh_slots(state) do
    candidates = state.nodes |> Map.values() |> Enum.filter(&Process.alive?/1)

    case any_command(candidates, ["CLUSTER", "SLOTS"], 2_000) do
      {:ok, list} when is_list(list) ->
        {:ok, %{state | ranges: Enum.map(list, &parse_range/1)}}

      {:ok, other} ->
        {:error, Error.protocol("unexpected CLUSTER SLOTS reply: #{inspect(other)}")}

      {:error, _} = err ->
        err
    end
  end

  defp any_command([], _args, _timeout),
    do: {:error, Error.connection("no reachable cluster seed node")}

  defp any_command([pid | rest], args, timeout) do
    case Connection.command(pid, args, timeout) do
      {:ok, _} = ok -> ok
      {:error, _} -> any_command(rest, args, timeout)
    end
  end

  defp parse_range([start_slot, end_slot, master | replicas]) do
    %{
      start: start_slot,
      end: end_slot,
      master: node_addr(master),
      replicas: Enum.map(replicas, &node_addr/1)
    }
  end

  defp node_addr([ip, port | _rest]), do: {ip, port}

  defp ensure_node(state, {_host, _port} = addr) do
    case Map.fetch(state.nodes, addr) do
      {:ok, pid} ->
        if Process.alive?(pid) do
          {{:ok, pid}, state}
        else
          start_node(state, addr)
        end

      :error ->
        start_node(state, addr)
    end
  end

  defp start_node(state, {host, port} = addr) do
    opts = state.base_opts |> Keyword.put(:host, host) |> Keyword.put(:port, port)

    case Connection.start_link(opts) do
      {:ok, pid} -> {{:ok, pid}, %{state | nodes: Map.put(state.nodes, addr, pid)}}
      {:error, reason} -> {{:error, reason}, state}
    end
  end

  @doc false
  # Exposed for HotKV.Options-based unit tests of address parsing only.
  def __parse_host_port__(spec), do: parse_host_port(spec)
end
