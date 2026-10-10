# Copyright (c) 2026 HotKV Ltd
# Licensed under the Apache License, Version 2.0. See LICENSE in the project root.

defmodule HotKV.NumericTest do
  use ExUnit.Case, async: true

  alias HotKV.{Numeric, RESP}

  doctest HotKV.Numeric

  defp wire(args), do: args |> RESP.encode() |> IO.iodata_to_binary()
  defp arg(value), do: wire([value]) |> String.split("\r\n") |> Enum.at(2)

  describe "format_float/1" do
    test "tiny values print as plain decimals, never with an exponent" do
      assert Numeric.format_float(1.0e-5) == "0.00001"
      assert Numeric.format_float(1.5e-7) == "0.00000015"
      assert Numeric.format_float(-1.0e-5) == "-0.00001"
      assert Numeric.format_float(1.0e-10) == "0.0000000001"
      assert Numeric.format_float(5.0e-324) =~ ~r/\A0\.0{323}5\z/
    end

    test "huge values print as plain decimals" do
      assert Numeric.format_float(1.0e22) == "10000000000000000000000.0"
      assert Numeric.format_float(1.5e16) == "15000000000000000.0"
      assert Numeric.format_float(-2.5e20) == "-250000000000000000000.0"
      assert Numeric.format_float(1.7976931348623157e308) =~ ~r/\A17976931348623157\d{292}\.0\z/
    end

    test "ordinary and integral values are unchanged" do
      assert Numeric.format_float(1.5) == "1.5"
      assert Numeric.format_float(-0.25) == "-0.25"
      assert Numeric.format_float(0.0) == "0.0"
      assert Numeric.format_float(5.0) == "5.0"
      assert Numeric.format_float(100.0) == "100.0"
      assert Numeric.format_float(123_456.789) == "123456.789"
    end

    test "never contains an exponent and always reads back as the same float" do
      samples =
        [
          1.0e-300,
          1.0e-100,
          1.0e-20,
          9.99e-6,
          1.0e-4,
          0.1,
          0.3,
          1.0e15,
          1.0e16,
          1.2345e17,
          1.0e100,
          4.9e-324
        ] ++
          for(e <- -30..30, m <- [1.0, 1.5, 9.99, 2.2250738585072014], do: m * :math.pow(10, e))

      for f <- samples, f2 <- [f, -f] do
        text = Numeric.format_float(f2)
        refute text =~ ~r/[eE]/, "#{inspect(f2)} -> #{text}"
        assert text =~ ~r/\A-?\d+\.\d+\z/, "#{inspect(f2)} -> #{text}"
        assert String.to_float(text) == f2, "#{inspect(f2)} -> #{text}"
      end
    end
  end

  describe "RESP.encode/1 applies the formatter to every float argument" do
    test "floats are plain decimals on the wire" do
      assert arg(1.0e-5) == "0.00001"
      assert arg(1.0e22) == "10000000000000000000000.0"
      assert arg(-3.5) == "-3.5"
      assert arg(2.0) == "2.0"
    end

    test "inf and -inf atoms are sent, :nan and nil and unencodable terms raise" do
      assert arg(:inf) == "inf"
      assert arg(:"-inf") == "-inf"
      assert_raise ArgumentError, ~r/NaN/, fn -> RESP.encode([:nan]) end
      assert_raise ArgumentError, ~r/nil/, fn -> RESP.encode([nil]) end
      assert_raise ArgumentError, ~r/cannot encode/, fn -> RESP.encode([%{}]) end
      assert_raise ArgumentError, ~r/cannot encode/, fn -> RESP.encode([{:a, 1}]) end
      assert_raise ArgumentError, ~r/cannot encode/, fn -> RESP.encode([["nested"]]) end
    end
  end

  describe "format_usd/1" do
    test "floats are rounded to 6 decimals, trimmed, without an exponent" do
      assert Numeric.format_usd(1.0e-5) == "0.00001"
      assert Numeric.format_usd(2.5e-6) in ["0.000002", "0.000003"]
      assert Numeric.format_usd(1.0e-7) == "0"
      assert Numeric.format_usd(12.5) == "12.5"
      assert Numeric.format_usd(100.0) == "100"
      assert Numeric.format_usd(0.1) == "0.1"
      assert Numeric.format_usd(1.0e10) == "10000000000"
      assert Numeric.format_usd(123_456_789.123456) == "123456789.123456"
    end

    test "integers pass through and strings in the grammar are sent verbatim" do
      assert Numeric.format_usd(0) == "0"
      assert Numeric.format_usd(7) == "7"
      assert Numeric.format_usd("12.340000") == "12.340000"
      assert Numeric.format_usd("0.000001") == "0.000001"
    end

    test "other strings are parsed as numbers; garbage becomes 0" do
      assert Numeric.format_usd("1e-3") == "0.001"
      assert Numeric.format_usd(" 3") == "0"
      assert Numeric.format_usd("abc") == "0"
      assert Numeric.format_usd("1.0000001") == "1"
    end

    test "negative values keep their sign so the server rejects them" do
      assert Numeric.format_usd(-1.5) == "-1.5"
      assert Numeric.format_usd(-3) == "-3"
      # a tiny negative rounds to zero, not to a signed "-0"
      assert Numeric.format_usd(-1.0e-9) == "0"
    end
  end
end
