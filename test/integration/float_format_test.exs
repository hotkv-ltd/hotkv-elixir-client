# Copyright (c) 2026 HotKV Ltd
# Licensed under the Apache License, Version 2.0. See LICENSE in the project root.

defmodule HotKV.FloatFormatIntegrationTest do
  @moduledoc """
  Live check that floats reach the server in a form it accepts. The
  server's fixed-point parsers (`LLMBUDGET.SET`, `LLMSTATS.PRICE SET`)
  reject an exponent, which is what `Float.to_string(1.0e-5)` prints.
  """
  use ExUnit.Case, async: true
  @moduletag :integration

  alias HotKV.{Geo, Hashes, LLMBudget, SortedSets, Strings, TestSupport}

  setup do
    {:ok, conn: TestSupport.start_conn()}
  end

  test "the server really rejects the exponent form (why the formatter exists)", %{conn: conn} do
    name = TestSupport.unique("fmt:raw") |> String.replace(":", "_")

    case HotKV.command(conn, ["LLMBUDGET.SET", name, 1000, "1.0e-5", 60]) do
      {:error, %HotKV.Error{kind: :not_licensed}} ->
        IO.puts("      SKIP (not licensed): LLMBUDGET")

      result ->
        assert {:error, %HotKV.Error{kind: :server, prefix: "ERR"}} = result
    end
  end

  test "LLMBUDGET.SET accepts tiny, large and integral float limits", %{conn: conn} do
    name = TestSupport.unique("fmt:budget") |> String.replace(":", "_")
    on_exit(fn -> HotKV.command(conn, ["LLMBUDGET.DROP", name]) end)

    LLMBudget.set(conn, name, 1000, 1.0e-5, 60)
    |> TestSupport.licensed_or_skip(fn result ->
      assert {:ok, "OK"} = result
      assert {:ok, status} = LLMBudget.status(conn, name)
      assert status["cost_limit_usd"] == "0.000010"

      assert {:ok, "OK"} = LLMBudget.set(conn, name, 1000, 12_345_678.5, 60)
      assert {:ok, %{"cost_limit_usd" => "12345678.500000"}} = LLMBudget.status(conn, name)

      assert {:ok, "OK"} = LLMBudget.set(conn, name, 1000, 100.0, 60)
      assert {:ok, %{"cost_limit_usd" => "100.000000"}} = LLMBudget.status(conn, name)

      assert {:ok, "OK"} = LLMBudget.set(conn, name, 1000, "0.5", 60)
      assert {:ok, %{"cost_limit_usd" => "0.500000"}} = LLMBudget.status(conn, name)

      # a negative limit is passed through and refused by the server
      assert {:error, %HotKV.Error{kind: :server}} = LLMBudget.set(conn, name, 1000, -1.0, 60)

      # CONSUME's cost is a plain double on the server
      assert {:ok, true} = LLMBudget.consume(conn, name, 5, 1.0e-6)
    end)
  end

  test "ZADD / ZSCORE with tiny, huge, negative and infinite scores", %{conn: conn} do
    key = TestSupport.unique("fmt:z")
    on_exit(fn -> HotKV.command(conn, ["DEL", key]) end)

    assert {:ok, 5} =
             SortedSets.zadd(conn, key, [
               {1.0e-5, "tiny"},
               {1.0e22, "huge"},
               {-1.5e-7, "negtiny"},
               {-2.0e20, "neghuge"},
               {5.0, "integral"}
             ])

    assert {:ok, 1.0e-5} = SortedSets.zscore(conn, key, "tiny")
    assert {:ok, 1.0e22} = SortedSets.zscore(conn, key, "huge")
    assert {:ok, -1.5e-7} = SortedSets.zscore(conn, key, "negtiny")
    assert {:ok, -2.0e20} = SortedSets.zscore(conn, key, "neghuge")
    assert {:ok, 5.0} = SortedSets.zscore(conn, key, "integral")

    assert {:ok, ["neghuge", "negtiny", "tiny", "integral", "huge"]} =
             SortedSets.zrange(conn, key, 0, -1)

    assert {:ok, ["tiny"]} = SortedSets.zrangebyscore(conn, key, 9.0e-6, 2.0e-5)
    assert {:ok, 1} = SortedSets.zcount(conn, key, 1.0e21, 1.0e23)

    assert {:ok, 1} = SortedSets.zadd(conn, key, [{:inf, "top"}])
    assert {:ok, :inf} = SortedSets.zscore(conn, key, "top")
    assert {:ok, 1} = SortedSets.zadd(conn, key, [{:"-inf", "bottom"}])
    assert {:ok, :"-inf"} = SortedSets.zscore(conn, key, "bottom")
  end

  test "INCRBYFLOAT / HINCRBYFLOAT with tiny, huge and negative increments", %{conn: conn} do
    key = TestSupport.unique("fmt:incr")
    hash = TestSupport.unique("fmt:hincr")
    on_exit(fn -> HotKV.command(conn, ["DEL", key, hash]) end)

    assert {:ok, "0.00001"} = Strings.incrbyfloat(conn, key, 1.0e-5)
    assert {:ok, "0.00002"} = Strings.incrbyfloat(conn, key, 1.0e-5)
    assert {:ok, "0.00001"} = Strings.incrbyfloat(conn, key, -1.0e-5)
    assert {:ok, "10000000000000000000000"} = Strings.incrbyfloat(conn, key, 1.0e22)
    assert {:ok, "0"} = Strings.incrbyfloat(conn, key, -1.0e22)

    assert {:ok, "0.000025"} = Hashes.hincrbyfloat(conn, hash, "f", 2.5e-5)
    assert {:ok, "-0.000025"} = Hashes.hincrbyfloat(conn, hash, "f", -5.0e-5)
  end

  test "GEOADD with tiny coordinates", %{conn: conn} do
    key = TestSupport.unique("fmt:geo")
    on_exit(fn -> HotKV.command(conn, ["DEL", key]) end)

    assert {:ok, 2} =
             Geo.geoadd(conn, key, [{1.0e-5, 1.0e-5, "tiny"}, {-122.4194, 37.7749, "sf"}])

    assert {:ok, [{lon, lat}, {sf_lon, _}]} = Geo.geopos(conn, key, ["tiny", "sf"])
    assert_in_delta lon, 1.0e-5, 1.0e-4
    assert_in_delta lat, 1.0e-5, 1.0e-4
    assert_in_delta sf_lon, -122.4194, 1.0e-3
  end
end
