# Copyright (c) 2026 HotKV Ltd
# Licensed under the Apache License, Version 2.0. See LICENSE in the project root.

defmodule HotKV.KeysIntegrationTest do
  use ExUnit.Case, async: true
  @moduletag :integration

  alias HotKV.{Keys, TestSupport}

  setup do
    conn = TestSupport.start_conn()
    k = TestSupport.unique("keys")

    on_exit(fn ->
      HotKV.command(conn, ["DEL", k, k <> ":2", k <> ":3", k <> ":dump"])
    end)

    {:ok, conn: conn, k: k}
  end

  test "DEL, EXISTS, TOUCH, UNLINK, TYPE, RANDOMKEY", %{conn: conn, k: k} do
    HotKV.command(conn, ["SET", k, "v"])
    assert {:ok, 1} = Keys.exists(conn, k)
    assert {:ok, 2} = Keys.exists(conn, [k, k])
    assert {:ok, 1} = Keys.touch(conn, k)
    assert {:ok, "string"} = Keys.type(conn, k)
    assert {:ok, "none"} = Keys.type(conn, k <> ":missing")
    assert {:ok, r} = Keys.randomkey(conn)
    assert is_binary(r)
    assert {:ok, 1} = Keys.unlink(conn, k)
    assert {:ok, 0} = Keys.exists(conn, k)
  end

  test "DEL removes one or several keys and counts them", %{conn: conn, k: k} do
    HotKV.command(conn, ["SET", k, "v"])
    HotKV.command(conn, ["SET", k <> ":2", "v"])
    assert {:ok, 0} = Keys.del(conn, k <> ":missing")
    assert {:ok, 1} = Keys.del(conn, k)
    assert {:ok, 1} = Keys.del(conn, [k <> ":2", k <> ":missing"])
    assert {:ok, 0} = Keys.exists(conn, [k, k <> ":2"])
  end

  test "expiry family: EXPIRE/PEXPIRE/TTL/PTTL/PERSIST/EXPIRETIME", %{conn: conn, k: k} do
    HotKV.command(conn, ["SET", k, "v"])
    assert {:ok, true} = Keys.expire(conn, k, 1000)
    assert {:ok, ttl} = Keys.ttl(conn, k)
    assert ttl > 0 and ttl <= 1000
    assert {:ok, pttl} = Keys.pttl(conn, k)
    assert pttl > 0
    assert {:ok, et} = Keys.expiretime(conn, k)
    assert et > 0
    assert {:ok, pet} = Keys.pexpiretime(conn, k)
    assert pet > 0
    assert {:ok, true} = Keys.persist(conn, k)
    assert {:ok, -1} = Keys.ttl(conn, k)
    assert {:ok, true} = Keys.pexpire(conn, k, 500_000)
    assert {:ok, true} = Keys.expire(conn, k, 2000, flag: :xx)
    assert {:ok, -2} = Keys.ttl(conn, k <> ":does-not-exist")
  end

  test "EXPIREAT/PEXPIREAT with NX/XX/GT/LT flags", %{conn: conn, k: k} do
    HotKV.command(conn, ["SET", k, "v"])
    future = System.os_time(:second) + 1000
    assert {:ok, true} = Keys.expireat(conn, k, future, flag: :nx)
    assert {:ok, false} = Keys.expireat(conn, k, future, flag: :nx)
    assert {:ok, true} = Keys.pexpireat(conn, k, (future + 1) * 1000, flag: :gt)
  end

  test "RENAME/RENAMENX", %{conn: conn, k: k} do
    k2 = k <> ":2"
    HotKV.command(conn, ["SET", k, "v"])
    assert {:ok, "OK"} = Keys.rename(conn, k, k2)
    assert {:ok, "v"} = HotKV.command(conn, ["GET", k2])
    HotKV.command(conn, ["SET", k, "other"])
    assert {:ok, false} = Keys.renamenx(conn, k, k2)
  end

  test "COPY and MOVE", %{conn: conn, k: k} do
    k2 = k <> ":2"
    HotKV.command(conn, ["SET", k, "v"])
    assert {:ok, true} = Keys.copy(conn, k, k2)
    assert {:ok, "v"} = HotKV.command(conn, ["GET", k2])
    assert {:ok, true} = Keys.move(conn, k2, 1)
    HotKV.command(conn, ["SELECT", "1"])
    assert {:ok, "v"} = HotKV.command(conn, ["GET", k2])
    HotKV.command(conn, ["DEL", k2])
    HotKV.command(conn, ["SELECT", "0"])
  end

  test "DUMP/RESTORE", %{conn: conn, k: k} do
    dest = k <> ":dump"
    HotKV.command(conn, ["SET", k, "restore-me"])
    assert {:ok, blob} = Keys.dump(conn, k)
    assert is_binary(blob)
    assert {:ok, "OK"} = Keys.restore(conn, dest, 0, blob)
    assert {:ok, "restore-me"} = HotKV.command(conn, ["GET", dest])
  end

  test "OBJECT ENCODING", %{conn: conn, k: k} do
    HotKV.command(conn, ["SET", k, "v"])
    assert {:ok, encoding} = Keys.object_encoding(conn, k)
    assert is_binary(encoding)
  end

  test "KEYS and scan/2 both find a freshly-set key", %{conn: conn, k: k} do
    HotKV.command(conn, ["SET", k, "v"])
    assert {:ok, found} = Keys.keys(conn, k)
    assert k in found

    streamed = conn |> Keys.scan(match: k <> "*") |> Enum.to_list()
    assert k in streamed
  end
end
