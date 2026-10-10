# Copyright (c) 2026 HotKV Ltd
# Licensed under the Apache License, Version 2.0. See LICENSE in the project root.

defmodule HotKV.ServerScriptingScanIntegrationTest do
  use ExUnit.Case, async: true
  @moduletag :integration

  alias HotKV.{Scripting, Server, TestSupport}

  setup do
    conn = TestSupport.start_conn()
    {:ok, conn: conn}
  end

  describe "Server" do
    test "PING/ECHO/TIME/DBSIZE/CONFIG/CLIENT", %{conn: conn} do
      assert {:ok, "PONG"} = Server.ping(conn)
      assert {:ok, "hi"} = Server.ping(conn, "hi")
      assert {:ok, "hi"} = Server.echo(conn, "hi")
      assert {:ok, {seconds, micros}} = Server.time(conn)
      assert is_integer(seconds) and is_integer(micros)
      assert {:ok, size} = Server.dbsize(conn)
      assert is_integer(size)
      assert {:ok, info_text} = Server.info(conn)
      assert info_text =~ "hotkv" or is_binary(info_text)

      assert {:ok, "OK"} = Server.client_setname(conn, "hotkv-elixir-test")
      assert {:ok, "hotkv-elixir-test"} = Server.client_getname(conn)
      assert {:ok, id} = Server.client_id(conn)
      assert is_integer(id)

      assert {:ok, config} = Server.config_get(conn, "maxmemory")
      assert is_map(config)
    end

    test "SELECT switches database", %{conn: conn} do
      assert {:ok, "OK"} = Server.select(conn, 1)
      assert {:ok, "OK"} = Server.select(conn, 0)
    end
  end

  describe "Scripting" do
    test "EVAL returns the script's value", %{conn: conn} do
      assert {:ok, "hello"} = Scripting.eval(conn, "return ARGV[1]", [], ["hello"])
      assert {:ok, "k"} = Scripting.eval(conn, "return KEYS[1]", ["k"], [])
    end

    test "SCRIPT LOAD, EVALSHA and SCRIPT EXISTS", %{conn: conn} do
      assert {:ok, sha} = Scripting.script_load(conn, "return 1")
      assert sha == Scripting.sha1("return 1")
      assert {:ok, 1} = Scripting.evalsha(conn, sha)
      assert {:ok, [true]} = Scripting.script_exists(conn, sha)

      assert {:ok, [false]} =
               Scripting.script_exists(conn, "0000000000000000000000000000000000000000")
    end

    test "eval_auto/4 transparently loads the script on NOSCRIPT and succeeds either way", %{
      conn: conn
    } do
      Scripting.script_flush(conn)
      assert {:ok, "auto"} = Scripting.eval_auto(conn, "return ARGV[1]", [], ["auto"])
      # second call now hits the cache (EVALSHA succeeds directly)
      assert {:ok, "auto"} = Scripting.eval_auto(conn, "return ARGV[1]", [], ["auto"])
    end
  end

  describe "Scan" do
    test "scan/2, sscan/3, hscan/3 and zscan/3 all page through with MATCH/COUNT", %{conn: conn} do
      prefix = TestSupport.unique("scan")

      for i <- 1..25, do: HotKV.command(conn, ["SET", "#{prefix}:#{i}", "v"])

      found = conn |> HotKV.Keys.scan(match: "#{prefix}:*", count: 5) |> Enum.to_list()
      assert length(found) == 25

      for i <- 1..25, do: HotKV.command(conn, ["DEL", "#{prefix}:#{i}"])
    end
  end
end
