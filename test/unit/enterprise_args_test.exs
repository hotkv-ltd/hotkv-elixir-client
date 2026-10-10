# Copyright (c) 2026 HotKV Ltd
# Licensed under the Apache License, Version 2.0. See LICENSE in the project root.

defmodule HotKV.EnterpriseArgsTest do
  @moduledoc """
  Exact wire argument lists for the token usage and pricing options (the
  token usage group on `SCACHE.SET`,
  `PCACHE.SET`, every keyed cache `SET` and `LLMBUDGET.CONSUME`; the new
  `LLMSTATS.RECORD` options; `LLMSTATS.PRICE SET/GET/LIST/DEL`), and
  parsing of canned RESP2/RESP3 replies (including `LLMSTATS.PRICE`), all against `HotKV.TestSupport.FakeConn` instead of a
  live server.
  """

  use ExUnit.Case, async: true

  alias HotKV.{
    GuardCache,
    LLMBudget,
    LLMPrice,
    LLMStats,
    PromptCache,
    SemanticCache,
    TokenUsage,
    ToolCache
  }

  alias HotKV.TestSupport.FakeConn

  defp wire(args), do: FakeConn.wire(args)

  defp usage do
    TokenUsage.new("claude-sonnet-5",
      input_tokens: 100,
      output_tokens: 20,
      cache_read_tokens: 5,
      cache_write_5m_tokens: 7,
      cache_write_1h_tokens: 9
    )
  end

  # -- SCACHE.SET ---------------------------------------------------------

  test "SCACHE.SET without usage sends no usage group" do
    {:ok, conn} = FakeConn.start_link()
    assert {:ok, "OK"} = SemanticCache.set(conn, "ns", "q", "r", [1, 0])
    assert FakeConn.last_call(conn) == wire(["SCACHE.SET", "ns", "q", "r", 1, 0])
  end

  test "SCACHE.SET with ttl and usage" do
    {:ok, conn} = FakeConn.start_link()
    assert {:ok, "OK"} = SemanticCache.set(conn, "ns", "q", "r", [1, 0], ttl: 60, usage: usage())

    assert FakeConn.last_call(conn) ==
             wire([
               "SCACHE.SET",
               "ns",
               "q",
               "r",
               1,
               0,
               "TTL",
               60,
               "MODEL",
               "claude-sonnet-5",
               "INPUT",
               100,
               "OUTPUT",
               20,
               "CACHEREAD",
               5,
               "CACHEWRITE5M",
               7,
               "CACHEWRITE1H",
               9
             ])
  end

  test "SCACHE.STATS parses the new usage_saved_* fields from both reply shapes" do
    flat = [
      "entries",
      3,
      "hits",
      2,
      "misses",
      1,
      "hit_rate",
      "0.666667",
      "p50_us",
      120,
      "usage_saved_requests",
      2,
      "usage_saved_input_tokens",
      200,
      "usage_saved_output_tokens",
      40,
      "usage_saved_cache_read_tokens",
      10,
      "usage_saved_cache_write_tokens",
      5,
      "usage_saved_cost_usd",
      "0.000160"
    ]

    {:ok, conn} = FakeConn.start_link({:ok, flat})
    assert {:ok, stats} = SemanticCache.stats(conn, "ns")
    assert stats["usage_saved_input_tokens"] == 200
    assert stats["usage_saved_cost_usd"] == "0.000160"

    map_reply = flat |> Enum.chunk_every(2) |> Map.new(fn [k, v] -> {k, v} end)
    {:ok, conn2} = FakeConn.start_link({:ok, map_reply})
    assert {:ok, ^stats} = SemanticCache.stats(conn2, "ns")
  end

  # -- PCACHE.SET ---------------------------------------------------------

  test "PCACHE.SET without usage sends no usage group" do
    {:ok, conn} = FakeConn.start_link()
    assert {:ok, "OK"} = PromptCache.set(conn, "ns", "p", "r")
    assert FakeConn.last_call(conn) == wire(["PCACHE.SET", "ns", "p", "r"])
  end

  test "PCACHE.SET with ttl, meta and usage" do
    {:ok, conn} = FakeConn.start_link()

    assert {:ok, "OK"} =
             PromptCache.set(conn, "ns", "p", "r", ttl: 60, meta: "{}", usage: usage())

    assert FakeConn.last_call(conn) ==
             wire([
               "PCACHE.SET",
               "ns",
               "p",
               "r",
               "TTL",
               60,
               "META",
               "{}",
               "MODEL",
               "claude-sonnet-5",
               "INPUT",
               100,
               "OUTPUT",
               20,
               "CACHEREAD",
               5,
               "CACHEWRITE5M",
               7,
               "CACHEWRITE1H",
               9
             ])
  end

  test "PCACHE.SET with only a usage model omits zero counts" do
    {:ok, conn} = FakeConn.start_link()
    assert {:ok, "OK"} = PromptCache.set(conn, "ns", "p", "r", usage: TokenUsage.new("m"))
    assert FakeConn.last_call(conn) == wire(["PCACHE.SET", "ns", "p", "r", "MODEL", "m"])
  end

  test "PCACHE.STATS parses usage_saved_* fields" do
    flat = [
      "entries",
      1,
      "hits",
      0,
      "misses",
      1,
      "evictions",
      0,
      "memory_bytes",
      100,
      "hit_rate",
      "0.0",
      "p50_ns",
      1,
      "p95_ns",
      2,
      "p99_ns",
      3,
      "cost_saved_usd",
      "0.000000",
      "usage_saved_requests",
      0,
      "usage_saved_input_tokens",
      0,
      "usage_saved_output_tokens",
      0,
      "usage_saved_cache_read_tokens",
      0,
      "usage_saved_cache_write_tokens",
      0,
      "usage_saved_cost_usd",
      "0.000000"
    ]

    {:ok, conn} = FakeConn.start_link({:ok, flat})
    assert {:ok, stats} = PromptCache.stats(conn, "ns")
    assert stats["usage_saved_cost_usd"] == "0.000000"
    assert stats["usage_saved_requests"] == 0
  end

  # -- Keyed caches (TOOL.CACHE/NCACHE/GUARD/RERANK share one engine) ----

  test "keyed cache SET with usage" do
    {:ok, conn} = FakeConn.start_link()
    assert {:ok, "OK"} = ToolCache.set(conn, "ns", "k", "v", usage: usage())

    assert FakeConn.last_call(conn) ==
             wire([
               "TOOL.CACHE.SET",
               "ns",
               "k",
               "v",
               "MODEL",
               "claude-sonnet-5",
               "INPUT",
               100,
               "OUTPUT",
               20,
               "CACHEREAD",
               5,
               "CACHEWRITE5M",
               7,
               "CACHEWRITE1H",
               9
             ])
  end

  test "keyed cache SET with ttl/meta and no usage" do
    {:ok, conn} = FakeConn.start_link()
    assert {:ok, "OK"} = GuardCache.set(conn, "ns", "k", "v", ttl: 30, meta: "m")
    assert FakeConn.last_call(conn) == wire(["GUARD.SET", "ns", "k", "v", "TTL", 30, "META", "m"])
  end

  test "keyed cache STATS parses usage_saved_cost_usd" do
    flat = [
      "entries",
      1,
      "hits",
      1,
      "misses",
      0,
      "evictions",
      0,
      "memory_bytes",
      10,
      "usage_saved_requests",
      1,
      "usage_saved_input_tokens",
      10,
      "usage_saved_output_tokens",
      2,
      "usage_saved_cache_read_tokens",
      0,
      "usage_saved_cache_write_tokens",
      0,
      "usage_saved_cost_usd",
      "0.000030"
    ]

    {:ok, conn} = FakeConn.start_link({:ok, flat})
    assert {:ok, stats} = ToolCache.stats(conn, "ns")
    assert stats["usage_saved_cost_usd"] == "0.000030"
  end

  # -- LLMSTATS.RECORD -----------------------------------------------------

  test "LLMSTATS.RECORD legacy positional only" do
    {:ok, conn} = FakeConn.start_link()
    assert {:ok, "OK"} = LLMStats.record(conn, "b", 100, 20, 0, 0.01, 200)
    assert FakeConn.last_call(conn) == wire(["LLMSTATS.RECORD", "b", 100, 20, 0, "0.01", 200])
  end

  test "LLMSTATS.RECORD with the error flag" do
    {:ok, conn} = FakeConn.start_link()
    assert {:ok, "OK"} = LLMStats.record(conn, "b", 100, 20, 0, 0.01, 200, error: true)

    assert FakeConn.last_call(conn) ==
             wire([
               "LLMSTATS.RECORD",
               "b",
               100,
               20,
               0,
               "0.01",
               200,
               "ERROR",
               1
             ])
  end

  test "LLMSTATS.RECORD with model and cache write options" do
    {:ok, conn} = FakeConn.start_link()

    assert {:ok, "OK"} =
             LLMStats.record(conn, "b", 100, 20, 0, 0, 200,
               model: "claude-sonnet-5",
               cache_write_5m_tokens: 30,
               cache_write_1h_tokens: 40
             )

    assert FakeConn.last_call(conn) ==
             wire([
               "LLMSTATS.RECORD",
               "b",
               100,
               20,
               0,
               0,
               200,
               "MODEL",
               "claude-sonnet-5",
               "CACHEWRITE5M",
               30,
               "CACHEWRITE1H",
               40
             ])
  end

  test "LLMSTATS.GET parses the new fields from both reply shapes" do
    flat = [
      "requests",
      1,
      "errors",
      0,
      "input_tokens",
      100,
      "output_tokens",
      20,
      "cached_tokens",
      0,
      "cost_usd",
      "0.002",
      "avg_latency_ms",
      "200.0",
      "requests_1m",
      1,
      "tokens_1m",
      120,
      "cost_usd_1m",
      "0.002",
      "cache_write_5m_tokens",
      30,
      "cache_write_1h_tokens",
      40,
      "unpriced_requests",
      0
    ]

    {:ok, conn} = FakeConn.start_link({:ok, flat})
    assert {:ok, stats} = LLMStats.get(conn, "b")
    assert stats["cache_write_5m_tokens"] == 30
    assert stats["cache_write_1h_tokens"] == 40
    assert stats["unpriced_requests"] == 0

    map_reply = flat |> Enum.chunk_every(2) |> Map.new(fn [k, v] -> {k, v} end)
    {:ok, conn2} = FakeConn.start_link({:ok, map_reply})
    assert {:ok, ^stats} = LLMStats.get(conn2, "b")
  end

  # -- LLMSTATS.PRICE -------------------------------------------------------

  test "LLMSTATS.PRICE SET with required fields only" do
    {:ok, conn} = FakeConn.start_link()
    assert {:ok, "OK"} = LLMStats.price_set(conn, "m", 3, 15)

    assert FakeConn.last_call(conn) ==
             wire([
               "LLMSTATS.PRICE",
               "SET",
               "m",
               "INPUT",
               "3",
               "OUTPUT",
               "15"
             ])
  end

  test "LLMSTATS.PRICE SET with optional cache prices" do
    {:ok, conn} = FakeConn.start_link()

    assert {:ok, "OK"} =
             LLMStats.price_set(conn, "m", 3, 15,
               cache_read_usd_per_mtok: 0.3,
               cache_write_5m_usd_per_mtok: 3.75,
               cache_write_1h_usd_per_mtok: 6
             )

    assert FakeConn.last_call(conn) ==
             wire([
               "LLMSTATS.PRICE",
               "SET",
               "m",
               "INPUT",
               "3",
               "OUTPUT",
               "15",
               "CACHEREAD",
               "0.3",
               "CACHEWRITE5M",
               "3.75",
               "CACHEWRITE1H",
               "6"
             ])
  end

  test "LLMSTATS.PRICE SET accepts decimal strings unchanged" do
    {:ok, conn} = FakeConn.start_link()
    assert {:ok, "OK"} = LLMStats.price_set(conn, "m", "3", "15.000001")

    assert FakeConn.last_call(conn) ==
             wire([
               "LLMSTATS.PRICE",
               "SET",
               "m",
               "INPUT",
               "3",
               "OUTPUT",
               "15.000001"
             ])
  end

  test "LLMSTATS.PRICE GET argument list and a typed result" do
    reply = [
      "model",
      "m",
      "source",
      "unpriced",
      "priced",
      0,
      "retired",
      0,
      "input_usd_per_mtok",
      "0.000000",
      "output_usd_per_mtok",
      "0.000000",
      "cache_read_usd_per_mtok",
      "0.000000",
      "cache_write_5m_usd_per_mtok",
      "0.000000",
      "cache_write_1h_usd_per_mtok",
      "0.000000"
    ]

    {:ok, conn} = FakeConn.start_link({:ok, reply})

    assert {:ok, %LLMPrice{model: "m", source: "unpriced", priced: false}} =
             LLMStats.price_get(conn, "m")

    assert FakeConn.last_call(conn) == wire(["LLMSTATS.PRICE", "GET", "m"])
  end

  test "LLMSTATS.PRICE LIST parses an array of entries" do
    entry = [
      "model",
      "m",
      "source",
      "default",
      "priced",
      1,
      "retired",
      0,
      "input_usd_per_mtok",
      "3.000000",
      "output_usd_per_mtok",
      "15.000000",
      "cache_read_usd_per_mtok",
      "0.300000",
      "cache_write_5m_usd_per_mtok",
      "3.750000",
      "cache_write_1h_usd_per_mtok",
      "6.000000"
    ]

    {:ok, conn} = FakeConn.start_link({:ok, [entry, entry]})
    assert {:ok, [%LLMPrice{model: "m"}, %LLMPrice{model: "m"}]} = LLMStats.price_list(conn)
    assert FakeConn.last_call(conn) == wire(["LLMSTATS.PRICE", "LIST"])
  end

  test "LLMSTATS.PRICE LIST on an empty table" do
    {:ok, conn} = FakeConn.start_link({:ok, []})
    assert {:ok, []} = LLMStats.price_list(conn)
  end

  test "LLMSTATS.PRICE DEL argument list and boolean reply" do
    {:ok, conn} = FakeConn.start_link({:ok, 1})
    assert {:ok, true} = LLMStats.price_del(conn, "m")
    assert FakeConn.last_call(conn) == wire(["LLMSTATS.PRICE", "DEL", "m"])
  end

  # -- LLMBUDGET.CONSUME ----------------------------------------------------

  test "LLMBUDGET.CONSUME legacy positional" do
    {:ok, conn} = FakeConn.start_link({:ok, 1})
    assert {:ok, true} = LLMBudget.consume(conn, "b", 100, 0.01)
    assert FakeConn.last_call(conn) == wire(["LLMBUDGET.CONSUME", "b", 100, "0.01"])
  end

  test "LLMBUDGET.CONSUME with usage sends the zeroed positional tokens/cost" do
    {:ok, conn} = FakeConn.start_link({:ok, 1})
    assert {:ok, true} = LLMBudget.consume(conn, "b", 0, 0, usage())

    assert FakeConn.last_call(conn) ==
             wire([
               "LLMBUDGET.CONSUME",
               "b",
               0,
               0,
               "MODEL",
               "claude-sonnet-5",
               "INPUT",
               100,
               "OUTPUT",
               20,
               "CACHEREAD",
               5,
               "CACHEWRITE5M",
               7,
               "CACHEWRITE1H",
               9
             ])
  end

  test "LLMBUDGET.STATUS parses unpriced_requests" do
    flat = [
      "tokens_used",
      100,
      "token_limit",
      1000,
      "cost_used_usd",
      "0.01",
      "cost_limit_usd",
      "5.0",
      "window_seconds",
      3600,
      "window_remaining",
      1800,
      "requests_allowed",
      1,
      "requests_rejected",
      0,
      "unpriced_requests",
      0
    ]

    {:ok, conn} = FakeConn.start_link({:ok, flat})
    assert {:ok, status} = LLMBudget.status(conn, "b")
    assert status["unpriced_requests"] == 0
  end
end
