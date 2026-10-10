# Copyright (c) 2026 HotKV Ltd
# Licensed under the Apache License, Version 2.0. See LICENSE in the project root.

defmodule HotKV.Numeric do
  @moduledoc """
  The one place this library turns an Elixir number into the text a HotKV
  command argument carries.

  `Float.to_string/1` prints a very small or very large float in exponent
  form (`1.0e-5`, `1.0e22`). Several HotKV parsers take plain decimals only
  (`LLMBUDGET.SET` and `LLMSTATS.PRICE SET` read an exact fixed-point USD
  amount and reject an exponent), so every float the library sends goes
  through `format_float/1` instead, which always prints a plain decimal:
  digits, an optional `-`, a `.`, no exponent, and never any locale effect.
  `HotKV.RESP.encode/1` applies it to every float argument, so
  `HotKV.command(conn, ["ZADD", "k", 1.0e-5, "m"])` is safe as well.

  `format_usd/1` is the stricter formatter for exact USD amounts.
  """

  @usd_grammar ~r/\A\d+(\.\d{1,6})?\z/

  @doc """
  Formats `float` as the shortest plain decimal that reads back as the same
  float: no exponent, at least one fractional digit (`5.0`, `0.00001`,
  `-1500000.0`).

      iex> HotKV.Numeric.format_float(1.0e-5)
      "0.00001"
      iex> HotKV.Numeric.format_float(1.0e22)
      "10000000000000000000000.0"
      iex> HotKV.Numeric.format_float(-2.5)
      "-2.5"
  """
  @spec format_float(float) :: String.t()
  def format_float(float) when is_float(float) do
    text = Float.to_string(float)

    case String.split(text, "e", parts: 2) do
      [_plain] -> text
      [mantissa, exponent] -> expand(mantissa, String.to_integer(exponent))
    end
  end

  # Rewrites "d.ddd" times 10^exponent as a plain decimal.
  defp expand(mantissa, exponent) do
    {sign, unsigned} =
      case mantissa do
        "-" <> rest -> {"-", rest}
        rest -> {"", rest}
      end

    [int_digits, frac_digits] = String.split(unsigned, ".", parts: 2)
    # Trailing zeros of the mantissa carry no information ("1.0e-5" is "1e-5").
    digits =
      case String.trim_trailing(int_digits <> frac_digits, "0") do
        "" -> "0"
        trimmed -> trimmed
      end

    # Position of the decimal point within `digits` once scaled.
    point = String.length(int_digits) + exponent

    body =
      cond do
        point <= 0 ->
          "0." <> String.duplicate("0", -point) <> digits

        point >= String.length(digits) ->
          digits <> String.duplicate("0", point - String.length(digits)) <> ".0"

        true ->
          binary_part(digits, 0, point) <>
            "." <> binary_part(digits, point, byte_size(digits) - point)
      end

    sign <> body
  end

  @doc """
  Formats `value` as an exact fixed-point USD amount, the grammar
  `LLMBUDGET.SET` and `LLMSTATS.PRICE SET` require: digits, an optional
  `.`, 1 to 6 fractional digits, no exponent, no `+`.

    * A binary that already matches that grammar is passed through
      unchanged (the caller's own exact decimal string).
    * Any other binary is parsed as a number first (`"1e-3"` becomes
      `"0.001"`); text that is not a number becomes `"0"`.
    * An integer is printed as is.
    * A float is rounded to 6 decimals (micro-dollars, the finest unit the
      server stores) with trailing zeros removed, `"0"` if that leaves
      nothing. A negative value keeps its `-` so the server rejects it
      rather than the library silently changing its meaning.

      iex> HotKV.Numeric.format_usd(1.0e-5)
      "0.00001"
      iex> HotKV.Numeric.format_usd(12.5)
      "12.5"
      iex> HotKV.Numeric.format_usd(3)
      "3"
  """
  @spec format_usd(String.t() | number) :: String.t()
  def format_usd(value) when is_binary(value) do
    if Regex.match?(@usd_grammar, value) do
      value
    else
      case Float.parse(value) do
        {number, _rest} -> format_usd(number)
        :error -> "0"
      end
    end
  end

  def format_usd(value) when is_integer(value), do: Integer.to_string(value)

  def format_usd(value) when is_float(value) do
    [int_part, frac_part] =
      value |> :erlang.float_to_binary(decimals: 6) |> String.split(".", parts: 2)

    result =
      case String.trim_trailing(frac_part, "0") do
        "" -> int_part
        frac -> int_part <> "." <> frac
      end

    # A tiny negative rounds to "-0": that is zero, and a bare "-0" would be
    # rejected as a signed amount.
    if result == "-0", do: "0", else: result
  end
end
