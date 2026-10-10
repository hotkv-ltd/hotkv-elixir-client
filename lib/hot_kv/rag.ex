# Copyright (c) 2026 HotKV Ltd
# Licensed under the Apache License, Version 2.0. See LICENSE in the project root.

defmodule HotKV.RAG do
  @moduledoc "`RAG.*`: retrieval-augmented generation pipelines (needs a server license that includes the RAG feature)."

  alias HotKV.{Args, Error, Reply}

  @type conn :: HotKV.conn()
  @type vector :: [float | integer]

  @doc """
  `RAG.CREATE name dimensions [STRATEGY fixed|sentence|paragraph] [CHUNK_SIZE n] [CHUNK_OVERLAP n]`
  -> `\"OK\"`. `opts`: `:strategy` (`:fixed` (default), `:sentence`,
  `:paragraph`, or `:fixed_size`), `:chunk_size` (default `512`),
  `:chunk_overlap` (default `64`).
  """
  @spec create(conn, String.t(), pos_integer, keyword) :: {:ok, String.t()} | {:error, Error.t()}
  def create(conn, name, dimensions, opts \\ []) do
    extra =
      []
      |> add_strategy(opts)
      |> Args.value(opts, :chunk_size, "CHUNK_SIZE")
      |> Args.value(opts, :chunk_overlap, "CHUNK_OVERLAP")

    HotKV.command(conn, ["RAG.CREATE", name, dimensions | extra])
  end

  defp add_strategy(acc, opts) do
    case Keyword.get(opts, :strategy) do
      nil ->
        acc

      strategy when strategy in [:fixed, :sentence, :paragraph, :fixed_size] ->
        acc ++ ["STRATEGY", Atom.to_string(strategy)]
    end
  end

  @doc """
  `RAG.INGEST pipeline doc_id text [META k1 v1 ...] [VECTORS vec1 vec2 ...]`
  -> the number of chunks ingested, or a server error if the pipeline does
  not exist or the vector count does not match. `opts[:meta]` is a flat
  `[key, value, ...]` list; `opts[:vectors]` is one float list per chunk
  `text` produces, `[[0.1, 0.2, 0.3], [0.4, 0.5, 0.6]]`.
  """
  @spec ingest(conn, String.t(), String.t(), String.t(), keyword) ::
          {:ok, integer} | {:error, Error.t()}
  def ingest(conn, pipeline, doc_id, text, opts \\ []) do
    extra = [] |> Args.list(opts, :meta, "META") |> add_vectors(opts)
    HotKV.command(conn, ["RAG.INGEST", pipeline, doc_id, text | extra])
  end

  defp add_vectors(acc, opts) do
    case Keyword.get(opts, :vectors) do
      nil -> acc
      [] -> acc
      vectors -> acc ++ ["VECTORS" | Enum.map(vectors, &join_vector/1)]
    end
  end

  @doc """
  `RAG.SEARCH pipeline query_text [K n] [ALPHA f] [VECTOR v1,v2,...] [FILTER k1 v1 ...]`
  -> `[%{chunk_id:, doc_id:, text:, score:, vector_score:, bm25_score:,
  meta:}, ...]`. `opts`: `:k` (default `5`), `:alpha` (vector-vs-BM25
  blend, default `0.5`), `:vector` (a float list), `:filter` (a flat
  `[key, value, ...]` list).
  """
  @spec search(conn, String.t(), String.t(), keyword) :: {:ok, [map]} | {:error, Error.t()}
  def search(conn, pipeline, query_text, opts \\ []) do
    extra =
      []
      |> Args.value(opts, :k, "K")
      |> Args.value(opts, :alpha, "ALPHA")
      |> add_vector(opts)
      |> Args.list(opts, :filter, "FILTER")

    conn
    |> HotKV.command(["RAG.SEARCH", pipeline, query_text | extra])
    |> Reply.map(&normalize_results/1)
  end

  defp add_vector(acc, opts) do
    case Keyword.get(opts, :vector) do
      nil -> acc
      floats -> acc ++ ["VECTOR", join_vector(floats)]
    end
  end

  defp normalize_results(list) do
    Enum.map(list, fn [chunk_id, doc_id, text, score, vector_score, bm25_score | meta_flat] ->
      %{
        chunk_id: chunk_id,
        doc_id: doc_id,
        text: text,
        score: Reply.to_double(score),
        vector_score: Reply.to_double(vector_score),
        bm25_score: Reply.to_double(bm25_score),
        meta: Reply.to_map(meta_flat)
      }
    end)
  end

  @doc """
  `RAG.STATS pipeline` -> `%{name:, dimensions:, totalDocs:, totalChunks:,
  totalIngested:, totalQueries:, chunkSize:, chunkStrategy:, chunkOverlap:}`.
  """
  @spec stats(conn, String.t()) :: {:ok, map} | {:error, Error.t()}
  def stats(conn, pipeline),
    do: conn |> HotKV.command(["RAG.STATS", pipeline]) |> Reply.map(&Reply.to_map/1)

  @doc "`RAG.DROP pipeline` -> `\"OK\"`, or a server error if the pipeline does not exist."
  @spec drop(conn, String.t()) :: {:ok, String.t()} | {:error, Error.t()}
  def drop(conn, pipeline), do: HotKV.command(conn, ["RAG.DROP", pipeline])

  @doc "`RAG.LIST` -> every pipeline name."
  @spec list(conn) :: {:ok, [String.t()]} | {:error, Error.t()}
  def list(conn), do: HotKV.command(conn, ["RAG.LIST"])

  defp join_vector(floats), do: Enum.map_join(floats, ",", &vec_component/1)
  defp vec_component(value) when is_float(value), do: HotKV.Numeric.format_float(value)
  defp vec_component(value), do: to_string(value)
end
