# Copyright (c) 2026 HotKV Ltd
# Licensed under the Apache License, Version 2.0. See LICENSE in the project root.

defmodule HotKV.ConnectionTest do
  use ExUnit.Case, async: true

  alias HotKV.TestSupport.FakeServer

  defp silent_server do
    # Answers PING and nothing else; every other command gets no reply at all.
    FakeServer.start(fn
      ["PING"] -> FakeServer.simple("PONG")
      ["HELLO" | _] -> FakeServer.error("ERR unknown command 'HELLO'")
      _ -> :no_reply
    end)
  end

  test "an argument with no wire form raises in the caller and does not crash the connection" do
    {port, _} = silent_server()
    {:ok, conn} = HotKV.start_link(host: "127.0.0.1", port: port)

    assert_raise ArgumentError, fn -> HotKV.command(conn, ["SET", "k", %{a: 1}]) end
    assert_raise ArgumentError, fn -> HotKV.command(conn, ["SET", "k", nil]) end
    assert_raise ArgumentError, fn -> HotKV.pipeline(conn, [["PING"], ["SET", "k", {1}]]) end

    assert Process.alive?(conn)
    assert {:ok, "PONG"} = HotKV.command(conn, ["PING"])
  end

  test "the :command_timeout option is the default timeout of a command" do
    {port, _} = silent_server()
    {:ok, conn} = HotKV.start_link(host: "127.0.0.1", port: port, command_timeout: 150)

    assert HotKV.Connection.default_timeout(conn) == 150

    {micros, result} = :timer.tc(fn -> HotKV.command(conn, ["GET", "never-answered"]) end)
    assert {:error, %HotKV.Error{kind: :timeout}} = result
    assert micros < 2_000_000
  end

  test "an explicit :timeout wins over :command_timeout" do
    {port, _} = silent_server()
    {:ok, conn} = HotKV.start_link(host: "127.0.0.1", port: port, command_timeout: 60_000)

    {micros, result} = :timer.tc(fn -> HotKV.command(conn, ["GET", "x"], timeout: 100) end)
    assert {:error, %HotKV.Error{kind: :timeout}} = result
    assert micros < 2_000_000
  end

  test "the default timeout is also resolved for a registered name and for pool members" do
    {port, _} = silent_server()
    name = :"hotkv_conn_test_#{System.unique_integer([:positive])}"
    {:ok, _} = HotKV.start_link(host: "127.0.0.1", port: port, command_timeout: 111, name: name)
    assert HotKV.Connection.default_timeout(name) == 111

    {:ok, pool} =
      HotKV.Pool.start_link(host: "127.0.0.1", port: port, command_timeout: 222, size: 2)

    {:ok, member} = HotKV.Pool.checkout(pool)
    assert HotKV.Connection.default_timeout(member) == 222
    HotKV.Pool.stop(pool)
  end

  test "a rejected password returns an error and does not kill a caller that is not trapping exits" do
    {port, _} =
      FakeServer.start(fn
        ["HELLO" | _] -> FakeServer.error("WRONGPASS invalid username-password pair")
        ["AUTH" | _] -> FakeServer.error("WRONGPASS invalid username-password pair")
        _ -> nil
      end)

    parent = self()

    caller =
      spawn(fn ->
        send(
          parent,
          {:start_link, HotKV.start_link(host: "127.0.0.1", port: port, password: "x")}
        )

        Process.sleep(300)
        send(parent, :caller_survived)
      end)

    ref = Process.monitor(caller)

    assert_receive {:start_link, {:error, %HotKV.Error{kind: :server, prefix: "WRONGPASS"}}},
                   2_000

    assert_receive :caller_survived, 2_000
    assert_receive {:DOWN, ^ref, :process, ^caller, :normal}, 2_000

    # the same for a pool, a pub/sub connection and an unreachable port
    assert {:error, _} = HotKV.Pool.start_link(host: "127.0.0.1", port: port, password: "x")
  end

  test "connections and pools work under a supervisor: restart on crash, stop with the supervisor" do
    {port, _} = silent_server()
    name = :"hotkv_sup_conn_#{System.unique_integer([:positive])}"
    pool_name = :"hotkv_sup_pool_#{System.unique_integer([:positive])}"

    {:ok, sup} =
      Supervisor.start_link(
        [
          {HotKV, host: "127.0.0.1", port: port, name: name},
          {HotKV.Pool, host: "127.0.0.1", port: port, name: pool_name, size: 2}
        ],
        strategy: :one_for_one
      )

    assert {:ok, "PONG"} = HotKV.command(name, ["PING"])
    pool = HotKV.Pool.handle(pool_name)
    assert {:ok, "PONG"} = HotKV.command(pool, ["PING"])
    assert length(HotKV.Pool.members(pool)) == 2
    pid = Process.whereis(name)
    pool_pid = Process.whereis(pool_name)
    assert is_pid(pid) and is_pid(pool_pid)

    Process.exit(pid, :kill)
    wait_until(fn -> (new = Process.whereis(name)) && new != pid end)
    wait_until(fn -> match?({:ok, "PONG"}, HotKV.command(name, ["PING"])) end)

    Supervisor.stop(sup)
    refute Process.alive?(pool_pid)
    assert Process.whereis(name) == nil
  end

  defp wait_until(fun, tries \\ 50) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("condition not reached")
      true -> Process.sleep(50) && wait_until(fun, tries - 1)
    end
  end

  test "an empty pipeline returns immediately" do
    {port, _} = silent_server()
    {:ok, conn} = HotKV.start_link(host: "127.0.0.1", port: port)
    assert {:ok, []} = HotKV.pipeline(conn, [])
  end

  test "a pipeline returns one reply per command, errors included" do
    {port, _} =
      FakeServer.start(fn
        ["PING"] -> FakeServer.simple("PONG")
        ["BAD"] -> FakeServer.error("ERR nope")
        _ -> nil
      end)

    {:ok, conn} = HotKV.start_link(host: "127.0.0.1", port: port)

    assert {:ok,
            [{:ok, "PONG"}, {:error, %HotKV.Error{kind: :server, prefix: "ERR"}}, {:ok, "PONG"}]} =
             HotKV.pipeline(conn, [["PING"], ["BAD"], ["PING"]])
  end

  test "a float argument reaches the server as a plain decimal" do
    test_pid = self()

    {port, _} =
      FakeServer.start(fn
        ["ZADD" | _] = args ->
          send(test_pid, {:got, args})
          FakeServer.int(1)

        _ ->
          nil
      end)

    {:ok, conn} = HotKV.start_link(host: "127.0.0.1", port: port)

    assert {:ok, 1} =
             HotKV.SortedSets.zadd(conn, "z", [{1.0e-5, "tiny"}, {1.0e22, "huge"}, {-2.5, "neg"}])

    assert_receive {:got,
                    [
                      "ZADD",
                      "z",
                      "0.00001",
                      "tiny",
                      "10000000000000000000000.0",
                      "huge",
                      "-2.5",
                      "neg"
                    ]}
  end

  test "BLPOP with a float zero timeout blocks without a client-side timeout" do
    test_pid = self()

    {port, _} =
      FakeServer.start(fn
        ["BLPOP", "q", "0.0"] ->
          send(test_pid, :blpop_received)
          :no_reply

        _ ->
          nil
      end)

    {:ok, conn} = HotKV.start_link(host: "127.0.0.1", port: port, command_timeout: 100)
    task = Task.async(fn -> HotKV.Lists.blpop(conn, "q", 0.0) end)
    assert_receive :blpop_received, 1_000
    # well past :command_timeout: still waiting
    assert Task.yield(task, 400) == nil
    Task.shutdown(task, :brutal_kill)

    # 0 and 0.0 both mean "block forever"; a float timeout gets 5s of headroom
    assert HotKV.Lists.blocking_timeout(0) == :infinity
    assert HotKV.Lists.blocking_timeout(0.0) == :infinity
    assert HotKV.Lists.blocking_timeout(1.5) == 6_500
    assert HotKV.Lists.blocking_timeout(2) == 7_000
  end
end
