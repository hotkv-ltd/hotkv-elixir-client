# Copyright (c) 2026 HotKV Ltd
# Licensed under the Apache License, Version 2.0. See LICENSE in the project root.

defmodule HotKV.CRC16Test do
  use ExUnit.Case, async: true

  alias HotKV.CRC16

  test "raw CRC16/XMODEM known vector" do
    assert CRC16.crc16("123456789") == 0x31C3
  end

  test "key_slot known vectors (matching CLUSTER KEYSLOT)" do
    vectors = [
      {"foo", 12182},
      {"bar", 5061},
      {"hello", 866},
      {"{user1000}.following", 3443},
      {"{user1000}.followers", 3443},
      {"{}foo", 9500},
      {"foo{}{bar}", 8363},
      {"foo{{bar}}zap", 4015},
      {"foo{bar}{zap}", 5061}
    ]

    for {key, expected_slot} <- vectors do
      assert CRC16.key_slot(key) == expected_slot,
             "expected key_slot(#{inspect(key)}) == #{expected_slot}"
    end
  end

  test "every slot is in range" do
    for key <- ["a", "some longer key", "{tag}rest", ""] do
      slot = CRC16.key_slot(key)
      assert slot >= 0 and slot <= 16383
    end
  end
end
