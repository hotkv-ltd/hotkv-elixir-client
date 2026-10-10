# Copyright (c) 2026 HotKV Ltd
# Licensed under the Apache License, Version 2.0. See LICENSE in the project root.

defmodule HotKV.PipelineTransactionIntegrationTest do
  use ExUnit.Case, async: true
  @moduletag :integration

  alias HotKV.TestSupport

  setup do
    conn = TestSupport.start_conn()
    k = TestSupport.unique("pipetx")
    on_exit(fn -> HotKV.command(conn, ["DEL", k, k <> ":2"]) end)
    {:ok, conn: conn, k: k}
  end

  describe "pipeline/3" do
    test "runs every command in one batch and returns results in order", %{conn: conn, k: k} do
      assert {:ok, results} =
               HotKV.pipeline(conn, [
                 ["SET", k, "1"],
                 ["INCR", k],
                 ["INCR", k],
                 ["GET", k]
               ])

      assert results == [{:ok, "OK"}, {:ok, 2}, {:ok, 3}, {:ok, "3"}]
    end

    test "one failing command does not fail the rest of the batch", %{conn: conn, k: k} do
      HotKV.command(conn, ["DEL", k])
      HotKV.command(conn, ["LPUSH", k, "x"])

      assert {:ok, [ok_reply, error_reply]} = HotKV.pipeline(conn, [["LLEN", k], ["GET", k]])

      assert ok_reply == {:ok, 1}
      assert {:error, %HotKV.Error{kind: :server, prefix: "WRONGTYPE"}} = error_reply
    end

    test "pipeline!/3 raises only on a connection-level failure, not on per-command errors", %{
      conn: conn,
      k: k
    } do
      results = HotKV.pipeline!(conn, [["SET", k, "v"], ["GET", k]])
      assert results == [{:ok, "OK"}, {:ok, "v"}]
    end
  end

  describe "transaction/3" do
    test "queued commands only apply on EXEC, and results come back in order", %{conn: conn, k: k} do
      assert {:ok, ["OK", 1, "1"]} =
               HotKV.transaction(conn, fn c ->
                 HotKV.command(c, ["SET", k, "0"])
                 HotKV.command(c, ["INCR", k])
                 HotKV.command(c, ["GET", k])
               end)
    end

    test "WATCH aborts the transaction (EXEC returns nil) if the key changes first", %{
      conn: conn,
      k: k
    } do
      HotKV.command(conn, ["SET", k, "1"])
      other = TestSupport.start_conn()

      assert {:ok, "OK"} = HotKV.watch(conn, [k])
      HotKV.command(other, ["SET", k, "changed"])

      assert {:ok, nil} =
               HotKV.transaction(conn, fn c ->
                 HotKV.command(c, ["SET", k, "2"])
               end)

      assert {:ok, "changed"} = HotKV.command(conn, ["GET", k])
    end

    test "an exception inside the transaction function sends DISCARD and re-raises", %{
      conn: conn,
      k: k
    } do
      assert_raise RuntimeError, "boom", fn ->
        HotKV.transaction(conn, fn c ->
          HotKV.command(c, ["SET", k, "should-not-stick"])
          raise "boom"
        end)
      end

      # the connection is usable again right after (MULTI state was cleaned up)
      assert {:ok, "PONG"} = HotKV.command(conn, ["PING"])
    end

    test "UNWATCH clears a previously watched key", %{conn: conn, k: k} do
      assert {:ok, "OK"} = HotKV.watch(conn, [k])
      assert {:ok, "OK"} = HotKV.unwatch(conn)
    end
  end
end
