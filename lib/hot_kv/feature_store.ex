# Copyright (c) 2026 HotKV Ltd
# Licensed under the Apache License, Version 2.0. See LICENSE in the project root.

defmodule HotKV.FeatureStore do
  @moduledoc "`FEATURE.*`: the online feature store (needs a server license that includes the feature-store feature)."

  alias HotKV.{Args, Error, Reply}

  @type conn :: HotKV.conn()

  @doc """
  `FEATURE.CREATE group description SCHEMA name1 type1 [name2 type2 ...]`
  -> `\"OK\"`. `schema` is `[{name, type}, ...]`; `type` is one of
  `"int64"`, `"double"` (alias `"float"`), `"string"`, `"int_array"`,
  `"double_array"` (alias `"float_array"`), case-insensitive.
  """
  @spec create(conn, String.t(), String.t(), [{String.t(), String.t()}]) ::
          {:ok, String.t()} | {:error, Error.t()}
  def create(conn, group, description, schema) do
    HotKV.command(conn, [
      "FEATURE.CREATE",
      group,
      description,
      "SCHEMA" | Enum.flat_map(schema, fn {n, t} -> [n, t] end)
    ])
  end

  @doc """
  `FEATURE.SET group entity feature1 value1 [feature2 value2 ...]` ->
  `\"OK\"`, or a server error if the group does not exist. `features` is
  `[{feature, value}, ...]`.
  """
  @spec set(conn, String.t(), String.t(), [{String.t(), term}]) ::
          {:ok, String.t()} | {:error, Error.t()}
  def set(conn, group, entity, features) do
    HotKV.command(conn, [
      "FEATURE.SET",
      group,
      entity | Enum.flat_map(features, fn {f, v} -> [f, v] end)
    ])
  end

  @doc """
  `FEATURE.GET group entity [feature1 feature2 ...]` -> `%{features:,
  updated_at_ms:, freshness_ms:}`, `nil` if the entity has no stored
  features. Omit `feature_names` for every feature.
  """
  @spec get(conn, String.t(), String.t(), [String.t()]) :: {:ok, map | nil} | {:error, Error.t()}
  def get(conn, group, entity, feature_names \\ []) do
    conn
    |> HotKV.command(["FEATURE.GET", group, entity | feature_names])
    |> Reply.map(&as_entity/1)
  end

  defp as_entity(nil), do: nil

  defp as_entity([flat_features, updated_at_ms, freshness_ms]) do
    %{
      features: Reply.to_map(flat_features),
      updated_at_ms: updated_at_ms,
      freshness_ms: freshness_ms
    }
  end

  @doc """
  `FEATURE.BATCH group entity1 entity2 ... [FEATURES f1 f2 ...]` -> one
  entry per entity, `nil` or `%{features:, updated_at_ms:, freshness_ms:}`,
  same order as `entities`.
  """
  @spec batch(conn, String.t(), [String.t()], [String.t()]) ::
          {:ok, [map | nil]} | {:error, Error.t()}
  def batch(conn, group, entities, feature_names \\ []) do
    extra = Args.list([], [features: feature_names], :features, "FEATURES")

    conn
    |> HotKV.command(["FEATURE.BATCH", group | entities] ++ extra)
    |> Reply.map(&Enum.map(&1, fn e -> as_entity(e) end))
  end

  @doc "`FEATURE.SCHEMA group` -> `[{name, type}, ...]`."
  @spec schema(conn, String.t()) :: {:ok, [{String.t(), String.t()}]} | {:error, Error.t()}
  def schema(conn, group) do
    conn
    |> HotKV.command(["FEATURE.SCHEMA", group])
    |> Reply.map(&Enum.map(&1, fn [name, type] -> {name, type} end))
  end

  @doc "`FEATURE.LIST` -> every group name."
  @spec list(conn) :: {:ok, [String.t()]} | {:error, Error.t()}
  def list(conn), do: HotKV.command(conn, ["FEATURE.LIST"])

  @doc "`FEATURE.DROP group` -> `\"OK\"`, or a server error if the group does not exist."
  @spec drop(conn, String.t()) :: {:ok, String.t()} | {:error, Error.t()}
  def drop(conn, group), do: HotKV.command(conn, ["FEATURE.DROP", group])

  @doc "`FEATURE.STATS group` -> `%{entities:, totalReads:, totalWrites:, memoryBytes:}`."
  @spec stats(conn, String.t()) :: {:ok, map} | {:error, Error.t()}
  def stats(conn, group),
    do: conn |> HotKV.command(["FEATURE.STATS", group]) |> Reply.map(&Reply.to_map/1)
end
