# Copyright (c) 2026 HotKV Ltd
# Licensed under the Apache License, Version 2.0. See LICENSE in the project root.

defmodule HotKV.WireArgsTest do
  @moduledoc """
  Exact request bytes for commands that are deliberately not run against
  the shared test server because they change global server state
  (`FLUSHALL` wipes everything), checked against `HotKV.TestSupport.FakeConn`.
  """
  use ExUnit.Case, async: true

  alias HotKV.TestSupport.FakeConn
  alias HotKV.Server

  defp last(fun, reply \\ {:ok, "OK"}) do
    {:ok, conn} = FakeConn.start_link(reply)
    fun.(conn)
    FakeConn.last_call(conn)
  end

  test "FLUSHALL and FLUSHDB modes" do
    assert last(&Server.flushall(&1)) == ["FLUSHALL"]
    assert last(&Server.flushall(&1, :async)) == ["FLUSHALL", "ASYNC"]
    assert last(&Server.flushall(&1, :sync)) == ["FLUSHALL", "SYNC"]
    assert last(&Server.flushdb(&1, :async)) == ["FLUSHDB", "ASYNC"]
  end

  test "new compare-and-set and newer commands" do
    alias HotKV.{Hashes, Strings}

    assert last(&Strings.set(&1, "k", "v", ifeq: "old", ex: 5)) == [
             "SET",
             "k",
             "v",
             "IFEQ",
             "old",
             "EX",
             "5"
           ]

    assert last(&Strings.delex(&1, "k", ifdeq: "00ff00ff00ff00ff"), {:ok, 1}) == [
             "DELEX",
             "k",
             "IFDEQ",
             "00ff00ff00ff00ff"
           ]

    assert last(&Strings.msetex(&1, [{"a", "1"}, {"b", "2"}], nx: true, px: 500), {:ok, 1}) == [
             "MSETEX",
             "2",
             "a",
             "1",
             "b",
             "2",
             "NX",
             "PX",
             "500"
           ]

    assert last(&Hashes.hgetdel(&1, "h", ["f1", "f2"])) == [
             "HGETDEL",
             "h",
             "FIELDS",
             "2",
             "f1",
             "f2"
           ]

    assert last(&Hashes.hgetex(&1, "h", ["f"], ex: 9)) == [
             "HGETEX",
             "h",
             "EX",
             "9",
             "FIELDS",
             "1",
             "f"
           ]

    assert last(&Hashes.hsetex(&1, "h", [{"f", "v"}], fnx: true, ex: 9), {:ok, 1}) == [
             "HSETEX",
             "h",
             "FNX",
             "EX",
             "9",
             "FIELDS",
             "1",
             "f",
             "v"
           ]
  end
end
