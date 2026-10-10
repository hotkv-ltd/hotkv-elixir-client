# Copyright (c) 2026 HotKV Ltd
# Licensed under the Apache License, Version 2.0. See LICENSE in the project root.

defmodule HotKV.LLMPrice do
  @moduledoc """
  One `LLMSTATS.PRICE` table entry: the reply of `HotKV.LLMStats.price_get/2`,
  and each element of `HotKV.LLMStats.price_list/1`. Prices are USD per
  1,000,000 tokens. `source` is `"default"` (built in), `"custom"` (set
  with `HotKV.LLMStats.price_set/5`) or `"unpriced"` (an unknown model:
  every price `0`, not an error).
  """

  alias HotKV.Reply

  defstruct model: "",
            source: "",
            priced: false,
            retired: false,
            input_usd_per_mtok: 0.0,
            output_usd_per_mtok: 0.0,
            cache_read_usd_per_mtok: 0.0,
            cache_write_5m_usd_per_mtok: 0.0,
            cache_write_1h_usd_per_mtok: 0.0

  @type t :: %__MODULE__{
          model: String.t(),
          source: String.t(),
          priced: boolean,
          retired: boolean,
          input_usd_per_mtok: float,
          output_usd_per_mtok: float,
          cache_read_usd_per_mtok: float,
          cache_write_5m_usd_per_mtok: float,
          cache_write_1h_usd_per_mtok: float
        }

  @doc """
  Builds an `LLMPrice` from `fields` (a `String.t()`-keyed map, e.g. the
  result of `HotKV.Reply.to_map/1` on an `LLMSTATS.PRICE GET`/`LIST`
  entry): unknown keys are ignored, missing ones default to `""`/`0`/
  `false`.
  """
  @spec from_fields(map) :: t
  def from_fields(fields) when is_map(fields) do
    %__MODULE__{
      model: str(fields, "model"),
      source: str(fields, "source"),
      priced: bool(fields, "priced"),
      retired: bool(fields, "retired"),
      input_usd_per_mtok: dbl(fields, "input_usd_per_mtok"),
      output_usd_per_mtok: dbl(fields, "output_usd_per_mtok"),
      cache_read_usd_per_mtok: dbl(fields, "cache_read_usd_per_mtok"),
      cache_write_5m_usd_per_mtok: dbl(fields, "cache_write_5m_usd_per_mtok"),
      cache_write_1h_usd_per_mtok: dbl(fields, "cache_write_1h_usd_per_mtok")
    }
  end

  defp str(fields, key) do
    case Map.get(fields, key, "") do
      value when is_binary(value) -> value
      value -> to_string(value)
    end
  end

  defp bool(fields, key), do: fields |> Map.get(key, 0) |> Reply.to_bool()

  defp dbl(fields, key) do
    case Reply.to_double(Map.get(fields, key, 0.0)) do
      value when is_float(value) -> value
      _other -> 0.0
    end
  end

  @doc """
  Formats `value` as the plain decimal string `LLMSTATS.PRICE SET`
  requires: digits, an optional `.`, 1 to 6 fractional digits, no sign, no
  exponent. A binary already matching that grammar is passed through
  unchanged (the caller's own decimal string); an integer or float is
  formatted to 6 decimals with trailing zeros (and a bare trailing `.`)
  trimmed, `"0"` if that leaves nothing. See `HotKV.Numeric.format_usd/1`.
  """
  @spec format_price(String.t() | number) :: String.t()
  def format_price(value), do: HotKV.Numeric.format_usd(value)
end
