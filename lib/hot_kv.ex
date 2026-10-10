# Copyright (c) 2026 HotKV Ltd
# Licensed under the Apache License, Version 2.0. See LICENSE in the project root.

defmodule HotKV do
  @moduledoc """
  Official Elixir client for HotKV.

  ## Quick start

      {:ok, conn} = HotKV.start_link(url: "hotkv://127.0.0.1:6379")
      {:ok, "OK"} = HotKV.command(conn, ["SET", "greeting", "hello"])
      {:ok, "hello"} = HotKV.command(conn, ["GET", "greeting"])

  Or under a supervisor, registered under a name so the rest of the app can
  just refer to `MyApp.HotKV`:

      children = [
        {HotKV, url: "hotkv://127.0.0.1:6379", name: MyApp.HotKV}
      ]

      HotKV.command(MyApp.HotKV, ["PING"])

  `command/2,3` is the generic escape hatch every command, including every
  HotKV-exclusive and AI command in the README, is ultimately built on. The
  typed wrapper modules (`HotKV.Strings`, `HotKV.Lists`, `HotKV.SortedSets`,
  `HotKV.SemanticCache`, `HotKV.PromptCache`, and friends) build the raw
  argument list for you and normalize the reply; reach for `command/2,3`
  directly for anything they don't cover.

  See the README for connection options (TLS, pooling), pipelines,
  transactions, pub/sub and the AI caching helpers.
  """

  alias HotKV.{Connection, Error, Pool}

  @type conn :: GenServer.server() | Pool.t()

  @doc false
  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :name, __MODULE__),
      start: {__MODULE__, :start_link, [opts]},
      type: :worker
    }
  end

  @doc """
  Starts a connection. `opts` accepts `:url` (a `hotkv://`/`hotkvs://`
  connection string) and/or any field of `HotKV.Options` directly (`:host`,
  `:port`, `:username`, `:password`, `:database`, `:tls`, `:tls_opts`,
  `:client_name`, `:connect_timeout`, `:command_timeout`, `:unix_socket`,
  ...), plus `:name` to register the process.

  Returns `{:ok, pid}`, or `{:error, reason}` if the initial connection
  could not be established within `:connect_timeout`.
  """
  @spec start_link(keyword) :: GenServer.on_start()
  def start_link(opts \\ []), do: Connection.start_link(opts)

  @doc "Sends one command, for example `HotKV.command(conn, [\"SET\", \"k\", \"v\"])`."
  @spec command(conn, [term], keyword) :: {:ok, term} | {:error, Error.t()}
  def command(conn, args, opts \\ [])

  def command(%Pool{} = pool, args, opts) do
    with {:ok, conn} <- Pool.checkout(pool), do: command(conn, args, opts)
  end

  def command(conn, args, opts) when is_list(args) do
    timeout = Keyword.get(opts, :timeout, :default)
    conn |> Connection.command(args, timeout) |> maybe_retry(conn, args, opts, timeout)
  end

  @doc "Like `command/3`, but returns the value directly and raises `HotKV.Error` on failure."
  @spec command!(conn, [term], keyword) :: term
  def command!(conn, args, opts \\ []), do: conn |> command(args, opts) |> bang!()

  @doc """
  Sends every command in `commands` in a single batch (one round trip) and
  returns their replies, in order, as `{:ok, [reply, ...]}` where each
  `reply` is itself `{:ok, term} | {:error, HotKV.Error.t()}` -- one
  command failing does not fail the rest of the batch. The outer
  `{:error, _}` only happens for a connection-level failure.
  """
  @spec pipeline(conn, [[term]], keyword) ::
          {:ok, [{:ok, term} | {:error, Error.t()}]} | {:error, Error.t()}
  def pipeline(conn, commands, opts \\ [])

  def pipeline(%Pool{} = pool, commands, opts) do
    with {:ok, conn} <- Pool.checkout(pool), do: pipeline(conn, commands, opts)
  end

  def pipeline(conn, commands, opts) when is_list(commands) do
    timeout = Keyword.get(opts, :timeout, :default)
    Connection.pipeline(conn, commands, timeout)
  end

  @doc "Like `pipeline/3`, but raises `HotKV.Error` if the batch itself could not be sent."
  @spec pipeline!(conn, [[term]], keyword) :: [{:ok, term} | {:error, Error.t()}]
  def pipeline!(conn, commands, opts \\ []), do: conn |> pipeline(commands, opts) |> bang!()

  @doc """
  Runs a `MULTI`/`EXEC` transaction on a single connection: sends `MULTI`,
  calls `fun.(conn)` (which should issue the transaction's commands with
  `HotKV.command/3`, whose replies will be the `"QUEUED"` acknowledgement,
  not the real result), then sends `EXEC`.

  Returns `{:ok, results}` with the real, ordered results of the queued
  commands, or `{:ok, nil}` if the transaction was aborted (a `WATCH`ed key
  changed). Call `HotKV.command(conn, ["WATCH", key])` before
  `transaction/3` to make the transaction conditional. If `fun` raises, a
  `DISCARD` is sent and the exception re-raised.

  When `conn` is a `HotKV.Pool`, one connection is checked out for the
  whole transaction so every command in it reaches the same server
  connection; `fun` receives that single connection, not the pool.
  """
  @spec transaction(conn, (GenServer.server() -> any), keyword) ::
          {:ok, term | nil} | {:error, Error.t()}
  def transaction(conn, fun, opts \\ []) when is_function(fun, 1) do
    with {:ok, real_conn} <- resolve(conn) do
      run_transaction(real_conn, fun, opts)
    end
  end

  defp resolve(%Pool{} = pool), do: Pool.checkout(pool)
  defp resolve(conn), do: {:ok, conn}

  defp run_transaction(conn, fun, opts) do
    case command(conn, ["MULTI"], opts) do
      {:ok, "OK"} ->
        try do
          fun.(conn)
          exec(conn, opts)
        rescue
          exception ->
            _ = command(conn, ["DISCARD"], opts)
            reraise exception, __STACKTRACE__
        end

      {:error, _} = error ->
        error
    end
  end

  defp exec(conn, opts) do
    case command(conn, ["EXEC"], opts) do
      {:ok, results} -> {:ok, results}
      {:error, _} = error -> error
    end
  end

  @doc "Marks `keys` so a following `transaction/3` aborts if any of them change first. See `transaction/3`."
  @spec watch(conn, [String.t()], keyword) :: {:ok, String.t()} | {:error, Error.t()}
  def watch(conn, keys, opts \\ []) when is_list(keys), do: command(conn, ["WATCH" | keys], opts)

  @doc "Clears all keys `watch/3` marked on `conn`."
  @spec unwatch(conn, keyword) :: {:ok, String.t()} | {:error, Error.t()}
  def unwatch(conn, opts \\ []), do: command(conn, ["UNWATCH"], opts)

  @doc "True if `conn` currently has a live socket to the server."
  @spec connected?(conn) :: boolean
  def connected?(%Pool{} = pool), do: Pool.any_connected?(pool)
  def connected?(conn), do: Connection.connected?(conn)

  @doc "Unwraps `{:ok, value}` to `value`, or raises the `HotKV.Error` in `{:error, error}`."
  @spec bang!({:ok, term} | {:error, Error.t()}) :: term
  def bang!({:ok, value}), do: value
  def bang!({:error, %Error{} = error}), do: raise(error)

  # -- idempotent-read retry-once -----------------------------------------

  @idempotent_commands ~w(
    GET MGET GETRANGE STRLEN EXISTS TYPE TTL PTTL EXPIRETIME PEXPIRETIME
    KEYS SCAN RANDOMKEY DUMP OBJECT
    LRANGE LLEN LINDEX LPOS
    SMEMBERS SISMEMBER SMISMEMBER SCARD SRANDMEMBER SUNION SINTER SDIFF SSCAN
    HGET HMGET HGETALL HKEYS HVALS HLEN HEXISTS HSCAN HRANDFIELD HTTL HPTTL
    ZSCORE ZMSCORE ZCARD ZCOUNT ZRANGE ZRANGEBYSCORE ZRANGEBYLEX ZREVRANGE
    ZREVRANGEBYSCORE ZRANK ZREVRANK ZSCAN ZRANDMEMBER ZUNION ZINTER ZDIFF
    XRANGE XREVRANGE XLEN XPENDING XINFO
    GEOPOS GEODIST GEOHASH GEOSEARCH
    GETBIT BITCOUNT BITPOS PFCOUNT
    PING ECHO INFO DBSIZE TIME CONFIG CLIENT HELLO
    NTTL TAG.GET TAG.MEMBERS TAG.INTER TAG.COUNT TAG.EXISTS HOTKEYS
    VSIM.GET VSIM.SEARCH VSIM.INFO
  )a |> MapSet.new(&to_string/1)

  @doc """
  True if `args`'s command name is one this library knows to be a read with
  no side effects, safe to retry automatically after a connection loss.
  """
  @spec idempotent?([term]) :: boolean
  def idempotent?([name | _]),
    do: MapSet.member?(@idempotent_commands, name |> to_string() |> String.upcase())

  def idempotent?(_), do: false

  defp maybe_retry({:error, %Error{kind: :connection}} = result, conn, args, opts, timeout) do
    if Keyword.get(opts, :retry, idempotent?(args)) do
      Connection.command(conn, args, timeout)
    else
      result
    end
  end

  defp maybe_retry(result, _conn, _args, _opts, _timeout), do: result
end
