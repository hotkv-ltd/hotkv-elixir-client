# Copyright (c) 2026 HotKV Ltd
# Licensed under the Apache License, Version 2.0. See LICENSE in the project root.

defmodule HotKV.StringsIntegrationTest do
  use ExUnit.Case, async: true
  @moduletag :integration

  alias HotKV.{Strings, TestSupport}

  setup do
    conn = TestSupport.start_conn()
    k = TestSupport.unique("str")
    on_exit(fn -> HotKV.command(conn, ["DEL", k, k <> ":2", k <> ":3"]) end)
    {:ok, conn: conn, k: k}
  end

  test "GET/SET round trip, and GET on a missing key is nil", %{conn: conn, k: k} do
    assert {:ok, nil} = Strings.get(conn, k)
    assert {:ok, "OK"} = Strings.set(conn, k, "hello")
    assert {:ok, "hello"} = Strings.get(conn, k)
  end

  test "SET with NX/XX/GET options", %{conn: conn, k: k} do
    assert {:ok, "OK"} = Strings.set(conn, k, "v1", nx: true)
    assert {:ok, nil} = Strings.set(conn, k, "v2", nx: true)
    assert {:ok, "v1"} = Strings.get(conn, k)
    assert {:ok, "v1"} = Strings.set(conn, k, "v3", xx: true, get: true)
    assert {:ok, "v3"} = Strings.get(conn, k)
  end

  test "SETNX, SETEX, PSETEX, GETSET, GETDEL, GETEX", %{conn: conn, k: k} do
    assert {:ok, true} = Strings.setnx(conn, k, "a")
    assert {:ok, false} = Strings.setnx(conn, k, "b")
    assert {:ok, "OK"} = Strings.setex(conn, k, 100, "c")
    assert {:ok, ttl} = HotKV.Keys.ttl(conn, k)
    assert ttl > 0
    assert {:ok, "OK"} = Strings.psetex(conn, k, 100_000, "d")
    assert {:ok, "d"} = Strings.getset(conn, k, "e")
    assert {:ok, "e"} = Strings.get(conn, k)
    assert {:ok, "e"} = Strings.getdel(conn, k)
    assert {:ok, nil} = Strings.get(conn, k)

    Strings.set(conn, k, "f")
    assert {:ok, "f"} = Strings.getex(conn, k, ex: 1000)
    assert {:ok, ttl2} = HotKV.Keys.ttl(conn, k)
    assert ttl2 > 0
    assert {:ok, "f"} = Strings.getex(conn, k, persist: true)
    assert {:ok, -1} = HotKV.Keys.ttl(conn, k)
  end

  test "APPEND, STRLEN, GETRANGE, SETRANGE", %{conn: conn, k: k} do
    assert {:ok, 5} = Strings.append(conn, k, "hello")
    assert {:ok, 10} = Strings.append(conn, k, "world")
    assert {:ok, 10} = Strings.strlen(conn, k)
    assert {:ok, "helloworld"} = Strings.getrange(conn, k, 0, -1)
    assert {:ok, "hello"} = Strings.getrange(conn, k, 0, 4)
    assert {:ok, 10} = Strings.setrange(conn, k, 5, "WORLD")
    assert {:ok, "helloWORLD"} = Strings.get(conn, k)
  end

  test "INCR family", %{conn: conn, k: k} do
    assert {:ok, 1} = Strings.incr(conn, k)
    assert {:ok, 11} = Strings.incrby(conn, k, 10)
    assert {:ok, 9} = Strings.decrby(conn, k, 2)
    assert {:ok, 8} = Strings.decr(conn, k)
    assert {:ok, incremented} = Strings.incrbyfloat(conn, k, 0.5)
    assert String.to_float(incremented) == 8.5
  end

  test "MGET/MSET/MSETNX", %{conn: conn, k: k} do
    k2 = k <> ":2"
    k3 = k <> ":3"
    assert {:ok, "OK"} = Strings.mset(conn, [{k, "1"}, {k2, "2"}])
    assert {:ok, ["1", "2", nil]} = Strings.mget(conn, [k, k2, k3])
    assert {:ok, false} = Strings.msetnx(conn, [{k, "x"}, {k3, "3"}])
    assert {:ok, nil} = Strings.get(conn, k3)
    assert {:ok, true} = Strings.msetnx(conn, [{k3, "3"}])
    assert {:ok, "3"} = Strings.get(conn, k3)
  end
end
