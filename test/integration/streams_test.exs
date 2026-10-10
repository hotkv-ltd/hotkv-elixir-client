# Copyright (c) 2026 HotKV Ltd
# Licensed under the Apache License, Version 2.0. See LICENSE in the project root.

defmodule HotKV.StreamsIntegrationTest do
  use ExUnit.Case, async: true
  @moduletag :integration

  alias HotKV.{Streams, TestSupport}

  setup do
    conn = TestSupport.start_conn()
    k = TestSupport.unique("stream")
    on_exit(fn -> HotKV.command(conn, ["DEL", k]) end)
    {:ok, conn: conn, k: k}
  end

  test "XADD/XLEN/XRANGE/XREVRANGE/XDEL", %{conn: conn, k: k} do
    assert {:ok, id1} = Streams.xadd(conn, k, "*", [{"field", "1"}])
    assert {:ok, id2} = Streams.xadd(conn, k, "*", ["field", "2"])
    assert {:ok, 2} = Streams.xlen(conn, k)
    assert {:ok, [{^id1, %{"field" => "1"}}, {^id2, %{"field" => "2"}}]} = Streams.xrange(conn, k)
    assert {:ok, [{^id2, _}, {^id1, _}]} = Streams.xrevrange(conn, k)
    assert {:ok, 1} = Streams.xdel(conn, k, id1)
    assert {:ok, 1} = Streams.xlen(conn, k)
  end

  test "XTRIM with MAXLEN", %{conn: conn, k: k} do
    for i <- 1..5, do: Streams.xadd(conn, k, "*", [{"i", Integer.to_string(i)}])
    assert {:ok, trimmed} = Streams.xtrim(conn, k, maxlen: 2)
    assert trimmed >= 3
    assert {:ok, 2} = Streams.xlen(conn, k)
  end

  test "XREAD reads new entries as a map keyed by stream", %{conn: conn, k: k} do
    {:ok, id} = Streams.xadd(conn, k, "*", [{"a", "1"}])
    assert {:ok, %{^k => [{^id, %{"a" => "1"}}]}} = Streams.xread(conn, [{k, "0"}])
    assert {:ok, nil} = Streams.xread(conn, [{k, "$"}], block: 200)
  end

  test "consumer groups: XGROUP, XREADGROUP, XACK, XPENDING, XCLAIM, XAUTOCLAIM", %{
    conn: conn,
    k: k
  } do
    {:ok, id} = Streams.xadd(conn, k, "*", [{"a", "1"}])
    assert {:ok, "OK"} = Streams.xgroup_create(conn, k, "g1", "0")

    assert {:ok, %{^k => [{^id, %{"a" => "1"}}]}} =
             Streams.xreadgroup(conn, "g1", "c1", [{k, ">"}])

    assert {:ok, [1, min_id, max_id, by_consumer]} = Streams.xpending(conn, k, "g1")
    assert min_id == id and max_id == id
    assert by_consumer == [["c1", "1"]]

    assert {:ok, [[^id, "c1", _idle, _delivered]]} = Streams.xpending(conn, k, "g1", "-", "+", 10)

    assert {:ok, [{^id, %{"a" => "1"}}]} = Streams.xclaim(conn, k, "g1", "c2", 0, id)
    assert {:ok, 1} = Streams.xack(conn, k, "g1", id)

    {:ok, id2} = Streams.xadd(conn, k, "*", [{"a", "2"}])
    Streams.xreadgroup(conn, "g1", "c1", [{k, ">"}])
    assert {:ok, {_cursor, [{^id2, _}], []}} = Streams.xautoclaim(conn, k, "g1", "c2", 0, "0")

    assert {:ok, true} = Streams.xgroup_createconsumer(conn, k, "g1", "c3")
    assert {:ok, _pending_count} = Streams.xgroup_delconsumer(conn, k, "g1", "c3")
    assert {:ok, "OK"} = Streams.xgroup_setid(conn, k, "g1", "0")
    assert {:ok, true} = Streams.xgroup_destroy(conn, k, "g1")
  end

  test "XINFO STREAM/GROUPS/CONSUMERS", %{conn: conn, k: k} do
    Streams.xadd(conn, k, "*", [{"a", "1"}])
    Streams.xgroup_create(conn, k, "g1", "0")
    Streams.xreadgroup(conn, "g1", "c1", [{k, ">"}])

    assert {:ok, info} = Streams.xinfo_stream(conn, k)
    assert info["length"] == 1

    assert {:ok, [group_info]} = Streams.xinfo_groups(conn, k)
    assert group_info["name"] == "g1"

    assert {:ok, [consumer_info]} = Streams.xinfo_consumers(conn, k, "g1")
    assert consumer_info["name"] == "c1"
  end
end
