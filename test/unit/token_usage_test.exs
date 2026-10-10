# Copyright (c) 2026 HotKV Ltd
# Licensed under the Apache License, Version 2.0. See LICENSE in the project root.

defmodule HotKV.TokenUsageTest do
  use ExUnit.Case, async: true

  alias HotKV.TokenUsage

  test "model only sends just MODEL" do
    usage = TokenUsage.new("claude-sonnet-5")
    assert TokenUsage.args([], usage) == ["MODEL", "claude-sonnet-5"]
  end

  test "zero counts are omitted from the wire" do
    usage =
      TokenUsage.new("claude-sonnet-5",
        input_tokens: 0,
        output_tokens: 0,
        cache_read_tokens: 0,
        cache_write_5m_tokens: 0,
        cache_write_1h_tokens: 0
      )

    assert TokenUsage.args([], usage) == ["MODEL", "claude-sonnet-5"]
  end

  test "non-zero counts are included in order" do
    usage =
      TokenUsage.new("claude-sonnet-5",
        input_tokens: 100,
        output_tokens: 20,
        cache_read_tokens: 5,
        cache_write_5m_tokens: 7,
        cache_write_1h_tokens: 9
      )

    assert TokenUsage.args([], usage) == [
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
           ]
  end

  test "a single non-zero count is included alone" do
    usage = TokenUsage.new("m", cache_write_1h_tokens: 3)
    assert TokenUsage.args([], usage) == ["MODEL", "m", "CACHEWRITE1H", 3]
  end

  test "args/2 appends to an existing accumulator" do
    usage = TokenUsage.new("m", input_tokens: 1)
    assert TokenUsage.args(["TTL", 60], usage) == ["TTL", 60, "MODEL", "m", "INPUT", 1]
  end

  test "nil usage is a no-op" do
    assert TokenUsage.args(["TTL", 60], nil) == ["TTL", 60]
  end

  test "model is required" do
    assert_raise FunctionClauseError, fn -> TokenUsage.new(nil) end
    assert_raise FunctionClauseError, fn -> TokenUsage.new("") end
  end

  test "building the struct directly without :model raises" do
    assert_raise ArgumentError, fn -> struct!(TokenUsage, input_tokens: 5) end
  end

  test "counts default to zero" do
    usage = TokenUsage.new("m")
    assert usage.input_tokens == 0
    assert usage.output_tokens == 0
    assert usage.cache_read_tokens == 0
    assert usage.cache_write_5m_tokens == 0
    assert usage.cache_write_1h_tokens == 0
  end
end
