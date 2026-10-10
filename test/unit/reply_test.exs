# Copyright (c) 2026 HotKV Ltd
# Licensed under the Apache License, Version 2.0. See LICENSE in the project root.

defmodule HotKV.ReplyTest do
  use ExUnit.Case, async: true

  alias HotKV.Reply

  test "map/2 transforms only the :ok half" do
    assert Reply.map({:ok, 1}, &(&1 + 1)) == {:ok, 2}
    assert Reply.map({:error, :boom}, &(&1 + 1)) == {:error, :boom}
  end

  test "to_map/1 accepts a native map or folds a flat RESP2 list" do
    assert Reply.to_map(%{"a" => "1"}) == %{"a" => "1"}
    assert Reply.to_map(["a", "1", "b", "2"]) == %{"a" => "1", "b" => "2"}
  end

  test "to_pairs/1 accepts a map, a RESP3 array-of-pairs, or a flat RESP2 list" do
    assert Reply.to_pairs(%{"a" => 1}) == [{"a", 1}]
    assert Reply.to_pairs([["a", 1], ["b", 2]]) == [{"a", 1}, {"b", 2}]
    assert Reply.to_pairs(["a", 1, "b", 2]) == [{"a", 1}, {"b", 2}]
    assert Reply.to_pairs([]) == []
  end

  test "to_set/1 accepts a MapSet or a plain list" do
    assert Reply.to_set(MapSet.new([1, 2])) == MapSet.new([1, 2])
    assert Reply.to_set([1, 2]) == MapSet.new([1, 2])
  end

  test "to_double/1 passes through floats and the RESP3 special atoms" do
    assert Reply.to_double(1.5) == 1.5
    assert Reply.to_double(:inf) == :inf
    assert Reply.to_double(:"-inf") == :"-inf"
    assert Reply.to_double(:nan) == :nan
  end

  test "to_double/1 parses RESP2 bulk-string scores, including integer-looking and special values" do
    assert Reply.to_double("3.5") == 3.5
    assert Reply.to_double("3") == 3.0
    assert Reply.to_double("-3") == -3.0
    assert Reply.to_double("inf") == :inf
    assert Reply.to_double("-inf") == :"-inf"
    assert Reply.to_double("nan") == :nan
  end

  test "to_bool/1 accepts 0/1 or a native boolean" do
    assert Reply.to_bool(0) == false
    assert Reply.to_bool(1) == true
    assert Reply.to_bool(true) == true
    assert Reply.to_bool(false) == false
  end

  test "ok?/1" do
    assert Reply.ok?("OK")
    refute Reply.ok?("NOT OK")
  end
end
