# Copyright (c) 2026 HotKV Ltd
# Licensed under the Apache License, Version 2.0. See LICENSE in the project root.

defmodule HotKV.LLMPriceTest do
  use ExUnit.Case, async: true

  alias HotKV.{LLMPrice, Reply}

  @resp2_flat [
    "model",
    "claude-sonnet-5",
    "source",
    "custom",
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

  defp parse(flat), do: flat |> Reply.to_map() |> LLMPrice.from_fields()

  test "parses a RESP2 flat pair array by field name" do
    price = parse(@resp2_flat)
    assert price.model == "claude-sonnet-5"
    assert price.source == "custom"
    assert price.priced == true
    assert price.retired == false
    assert_in_delta price.input_usd_per_mtok, 3.0, 1.0e-9
    assert_in_delta price.output_usd_per_mtok, 15.0, 1.0e-9
    assert_in_delta price.cache_read_usd_per_mtok, 0.3, 1.0e-9
    assert_in_delta price.cache_write_5m_usd_per_mtok, 3.75, 1.0e-9
    assert_in_delta price.cache_write_1h_usd_per_mtok, 6.0, 1.0e-9
  end

  test "parses a RESP3 native map identically" do
    map_reply = @resp2_flat |> Enum.chunk_every(2) |> Map.new(fn [k, v] -> {k, v} end)
    assert LLMPrice.from_fields(map_reply) == parse(@resp2_flat)
  end

  test "an unpriced model reports source unpriced and priced false, not an error" do
    fields = [
      "model",
      "unknown-model",
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

    price = parse(fields)
    assert price.source == "unpriced"
    assert price.priced == false
    assert price.input_usd_per_mtok == 0.0
  end

  test "missing fields default" do
    price = LLMPrice.from_fields(%{"model" => "m"})
    assert price.model == "m"
    assert price.source == ""
    assert price.priced == false
    assert price.retired == false
    assert price.input_usd_per_mtok == 0.0
  end

  test "an unknown extra field is ignored, not raised" do
    price = parse(@resp2_flat ++ ["brand_new_field", "x"])
    assert price.model == "claude-sonnet-5"
  end

  test "format_price/1 passes an already-valid decimal string through unchanged" do
    assert LLMPrice.format_price("15.000001") == "15.000001"
    assert LLMPrice.format_price("0.30") == "0.30"
  end

  test "format_price/1 formats integers and floats without exponent or trailing zeros" do
    assert LLMPrice.format_price(3) == "3"
    assert LLMPrice.format_price(0.30) == "0.3"
    assert LLMPrice.format_price(15.000001) == "15.000001"
    assert LLMPrice.format_price(0) == "0"
    assert LLMPrice.format_price(0.0) == "0"
    assert LLMPrice.format_price(100) == "100"
    assert LLMPrice.format_price(30.0) == "30"
  end
end
