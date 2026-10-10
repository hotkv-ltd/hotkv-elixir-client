# Copyright (c) 2026 HotKV Ltd
# Licensed under the Apache License, Version 2.0. See LICENSE in the project root.

defmodule HotKV.ConnectionIntegrationTest do
  use ExUnit.Case, async: true
  @moduletag :integration

  alias HotKV.TestSupport

  setup do
    conn = TestSupport.start_conn()
    on_exit(fn -> :ok end)
    {:ok, conn: conn}
  end

  test "start_link/1 connects and negotiates RESP3 by default", %{conn: conn} do
    assert HotKV.connected?(conn)
    assert HotKV.Connection.resp3?(conn)
    assert HotKV.command(conn, ["PING"]) == {:ok, "PONG"}
  end

  test "resp3: false stays on RESP2 (no HELLO), RESP2 replies keep their shape" do
    {:ok, conn} = HotKV.start_link(url: TestSupport.test_url(), resp3: false)
    refute HotKV.Connection.resp3?(conn)
    assert HotKV.command(conn, ["PING"]) == {:ok, "PONG"}

    key = TestSupport.unique("resp2")
    on_exit(fn -> HotKV.command(conn, ["DEL", key]) end)
    assert {:ok, 1} = HotKV.command(conn, ["HSET", key, "f", "1"])
    # a RESP2 HGETALL is a flat list, not a map
    assert {:ok, ["f", "1"]} = HotKV.command(conn, ["HGETALL", key])
    assert {:ok, %{"f" => "1"}} = HotKV.Hashes.hgetall(conn, key)
  end

  test "start_link/1 can be given options directly instead of a url" do
    url = URI.parse(TestSupport.test_url())
    {:ok, conn} = HotKV.start_link(host: url.host, port: url.port)
    assert HotKV.command(conn, ["PING"]) == {:ok, "PONG"}
  end

  test "command/2 generic escape hatch round-trips a value", %{conn: conn} do
    key = TestSupport.unique("conn")
    assert {:ok, "OK"} = HotKV.command(conn, ["SET", key, "v"])
    assert {:ok, "v"} = HotKV.command(conn, ["GET", key])
    HotKV.command(conn, ["DEL", key])
  end

  test "command!/2 returns the value directly and raises on server errors", %{conn: conn} do
    key = TestSupport.unique("conn")
    assert HotKV.command!(conn, ["SET", key, "v"]) == "OK"
    HotKV.command!(conn, ["LPUSH", key <> ":list", "x"])

    assert_raise HotKV.Error, fn ->
      HotKV.command!(conn, ["GET", key <> ":list"])
    end

    HotKV.command(conn, ["DEL", key, key <> ":list"])
  end

  test "server errors decode to a typed :server HotKV.Error", %{conn: conn} do
    key = TestSupport.unique("conn")
    HotKV.command(conn, ["DEL", key])
    HotKV.command!(conn, ["LPUSH", key, "x"])

    assert {:error, %HotKV.Error{kind: :server, prefix: "WRONGTYPE"}} =
             HotKV.command(conn, ["GET", key])

    HotKV.command(conn, ["DEL", key])
  end

  test "wrong arity is a normal server error, not a NOLICENSE-style error", %{conn: conn} do
    assert {:error, %HotKV.Error{kind: :server, prefix: "ERR"}} = HotKV.command(conn, ["GET"])
  end

  test "unknown command is a normal server error", %{conn: conn} do
    assert {:error, %HotKV.Error{kind: :server}} = HotKV.command(conn, ["THIS.IS.NOT.A.COMMAND"])
  end

  test "many requests can be in flight on one connection at once (pipelining under the hood)", %{
    conn: conn
  } do
    key = TestSupport.unique("conn:concurrent")

    tasks =
      for i <- 1..20 do
        Task.async(fn -> HotKV.command(conn, ["RPUSH", key, Integer.to_string(i)]) end)
      end

    results = Task.await_many(tasks)
    assert Enum.all?(results, &match?({:ok, _}, &1))
    assert {:ok, 20} = HotKV.command(conn, ["LLEN", key])
    HotKV.command(conn, ["DEL", key])
  end
end
