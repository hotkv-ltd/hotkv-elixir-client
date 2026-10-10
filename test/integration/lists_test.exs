# Copyright (c) 2026 HotKV Ltd
# Licensed under the Apache License, Version 2.0. See LICENSE in the project root.

defmodule HotKV.ListsIntegrationTest do
  use ExUnit.Case, async: true
  @moduletag :integration

  alias HotKV.{Lists, TestSupport}

  setup do
    conn = TestSupport.start_conn()
    k = TestSupport.unique("list")
    on_exit(fn -> HotKV.command(conn, ["DEL", k, k <> ":2"]) end)
    {:ok, conn: conn, k: k}
  end

  test "LPUSH/RPUSH/LRANGE/LLEN/LINDEX", %{conn: conn, k: k} do
    assert {:ok, 1} = Lists.rpush(conn, k, "b")
    assert {:ok, 2} = Lists.lpush(conn, k, "a")
    assert {:ok, 4} = Lists.rpush(conn, k, ["c", "d"])
    assert {:ok, 4} = Lists.llen(conn, k)
    assert {:ok, ["a", "b", "c", "d"]} = Lists.lrange(conn, k, 0, -1)
    assert {:ok, "a"} = Lists.lindex(conn, k, 0)
  end

  test "LPUSHX/RPUSHX no-op on a missing key", %{conn: conn, k: k} do
    assert {:ok, 0} = Lists.lpushx(conn, k, "x")
    assert {:ok, 0} = Lists.rpushx(conn, k, "x")
  end

  test "LPOP/RPOP with and without count", %{conn: conn, k: k} do
    Lists.rpush(conn, k, ["a", "b", "c", "d"])
    assert {:ok, "a"} = Lists.lpop(conn, k)
    assert {:ok, "d"} = Lists.rpop(conn, k)
    assert {:ok, ["b", "c"]} = Lists.lpop(conn, k, 5)
    assert {:ok, nil} = Lists.lpop(conn, k)
  end

  test "LRANGE/LINDEX/LSET/LINSERT/LREM/LTRIM", %{conn: conn, k: k} do
    Lists.rpush(conn, k, ["a", "b", "c"])
    assert {:ok, ["a", "b", "c"]} = Lists.lrange(conn, k, 0, -1)
    assert {:ok, "b"} = Lists.lindex(conn, k, 1)
    assert {:ok, "OK"} = Lists.lset(conn, k, 1, "B")
    assert {:ok, 4} = Lists.linsert(conn, k, :after, "B", "b2")
    assert {:ok, ["a", "B", "b2", "c"]} = Lists.lrange(conn, k, 0, -1)
    assert {:ok, 1} = Lists.lrem(conn, k, 0, "b2")
    assert {:ok, "OK"} = Lists.ltrim(conn, k, 0, 1)
    assert {:ok, ["a", "B"]} = Lists.lrange(conn, k, 0, -1)
  end

  test "RPOPLPUSH and LMOVE", %{conn: conn, k: k} do
    k2 = k <> ":2"
    Lists.rpush(conn, k, ["a", "b"])
    assert {:ok, "b"} = Lists.rpoplpush(conn, k, k2)
    assert {:ok, "a"} = Lists.lmove(conn, k, k2, :left, :right)
    assert {:ok, ["b", "a"]} = Lists.lrange(conn, k2, 0, -1)
  end

  test "LPOS", %{conn: conn, k: k} do
    Lists.rpush(conn, k, ["a", "b", "a", "c"])
    assert {:ok, 0} = Lists.lpos(conn, k, "a")
    assert {:ok, [0, 2]} = Lists.lpos(conn, k, "a", count: 0)
    assert {:ok, nil} = Lists.lpos(conn, k, "z")
  end

  test "BLPOP/BRPOP return immediately when an element is already available", %{conn: conn, k: k} do
    Lists.rpush(conn, k, "ready")
    assert {:ok, [^k, "ready"]} = Lists.blpop(conn, k, 1)
  end

  test "BLPOP times out and returns nil when nothing arrives", %{conn: conn, k: k} do
    assert {:ok, nil} = Lists.blpop(conn, k, 1)
  end
end
