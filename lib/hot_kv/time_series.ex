# Copyright (c) 2026 HotKV Ltd
# Licensed under the Apache License, Version 2.0. See LICENSE in the project root.

defmodule HotKV.TimeSeries do
  @moduledoc "`TS.*`: time series (needs a server license that includes the time-series feature)."

  alias HotKV.{Args, Error, Reply}

  @type conn :: HotKV.conn()
  @type key :: String.t()

  @doc """
  `TS.CREATE key [RETENTION ms] [LABELS l1 v1 ...]` -> `\"OK\"`. `opts`:
  `:retention` (ms), `:labels` (a flat `[label, value, ...]` list).
  """
  @spec create(conn, key, keyword) :: {:ok, String.t()} | {:error, Error.t()}
  def create(conn, key, opts \\ []) do
    # LABELS reads values until the RETENTION keyword or end of args, so
    # RETENTION must be emitted first when both are given.
    extra = [] |> Args.value(opts, :retention, "RETENTION") |> Args.list(opts, :labels, "LABELS")
    HotKV.command(conn, ["TS.CREATE", key | extra])
  end

  @doc "`TS.ADD key timestamp|* value` -> the timestamp (ms) used, or a server error if `key` was not created with `create/3`."
  @spec add(conn, key, integer | String.t(), number) :: {:ok, integer} | {:error, Error.t()}
  def add(conn, key, timestamp, value),
    do: HotKV.command(conn, ["TS.ADD", key, timestamp, value_arg(value)])

  defp value_arg(value) when is_float(value), do: HotKV.Numeric.format_float(value)
  defp value_arg(value), do: value

  @doc """
  `TS.RANGE key from_ms to_ms [COUNT n]` -> `[{timestamp_ms, value}, ...]`.
  `from_ms`/`to_ms` accept the literals `"-"` (= 0) and `"+"` (= max int64)
  in addition to a numeric ms timestamp.
  """
  @spec range(conn, key, integer | String.t(), integer | String.t(), keyword) ::
          {:ok, [{integer, float}]} | {:error, Error.t()}
  def range(conn, key, from_ms, to_ms, opts \\ []) do
    extra = Args.value([], opts, :count, "COUNT")
    conn |> HotKV.command(["TS.RANGE", key, from_ms, to_ms | extra]) |> as_series()
  end

  @doc "`TS.AGG key from_ms to_ms bucket_ms agg_type` -> `[{timestamp_ms, value}, ...]`, bucketed. `agg_type`: `:avg`, `:min`, `:max`, `:sum`, `:count`."
  @spec agg(conn, key, integer | String.t(), integer | String.t(), pos_integer, atom) ::
          {:ok, [{integer, float}]} | {:error, Error.t()}
  def agg(conn, key, from_ms, to_ms, bucket_ms, agg_type)
      when agg_type in [:avg, :min, :max, :sum, :count] do
    conn
    |> HotKV.command(["TS.AGG", key, from_ms, to_ms, bucket_ms, Atom.to_string(agg_type)])
    |> as_series()
  end

  defp as_series(result) do
    Reply.map(result, fn list ->
      Enum.map(list, fn [ts, value] -> {ts, Reply.to_double(value)} end)
    end)
  end

  @doc """
  `TS.INFO key` -> `%{"key" => ..., "totalSamples" => ..., ..., "labels" =>
  %{label => value}, "rules" => count}`.
  """
  @spec info(conn, key) :: {:ok, map} | {:error, Error.t()}
  def info(conn, key) do
    conn
    |> HotKV.command(["TS.INFO", key])
    |> Reply.map(fn flat ->
      flat
      |> Reply.to_map()
      |> Map.update!("labels", fn nested -> nested |> Reply.to_pairs() |> Map.new() end)
    end)
  end

  @doc "`TS.DELETE key` -> `\"OK\"`, or a server error if the series does not exist."
  @spec delete(conn, key) :: {:ok, String.t()} | {:error, Error.t()}
  def delete(conn, key), do: HotKV.command(conn, ["TS.DELETE", key])

  @doc "`TS.RETENTION key retention_ms` -> `\"OK\"`, or a server error if the series does not exist."
  @spec retention(conn, key, pos_integer) :: {:ok, String.t()} | {:error, Error.t()}
  def retention(conn, key, retention_ms),
    do: HotKV.command(conn, ["TS.RETENTION", key, retention_ms])

  @doc "`TS.DOWNSAMPLE src_key dest_key agg_type bucket_ms` -> `\"OK\"`. Adds a live downsample rule; both keys must already exist."
  @spec downsample(conn, key, key, atom, pos_integer) :: {:ok, String.t()} | {:error, Error.t()}
  def downsample(conn, src_key, dest_key, agg_type, bucket_ms)
      when agg_type in [:avg, :min, :max, :sum, :count] do
    HotKV.command(conn, ["TS.DOWNSAMPLE", src_key, dest_key, Atom.to_string(agg_type), bucket_ms])
  end

  @doc "`TS.LIST [LABEL key value]` -> every series key, optionally filtered to series carrying `{label_key, label_value}`."
  @spec list(conn, {String.t(), String.t()} | nil) :: {:ok, [key]} | {:error, Error.t()}
  def list(conn, label \\ nil)
  def list(conn, nil), do: HotKV.command(conn, ["TS.LIST"])

  def list(conn, {label_key, label_value}),
    do: HotKV.command(conn, ["TS.LIST", "LABEL", label_key, label_value])
end
