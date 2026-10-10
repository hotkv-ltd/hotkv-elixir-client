# Copyright (c) 2026 HotKV Ltd
# Licensed under the Apache License, Version 2.0. See LICENSE in the project root.

defmodule HotKV.Args do
  @moduledoc false
  # Small helpers command wrapper modules use to build the optional,
  # `KEYWORD value` (or bare `KEYWORD`) trailing arguments most commands
  # accept, from a caller-supplied keyword list.

  @doc "Appends `token` to `acc` when `opts[key]` is truthy."
  def flag(acc, opts, key, token) do
    if Keyword.get(opts, key), do: acc ++ [token], else: acc
  end

  @doc "Appends `[token, value]` to `acc` when `opts[key]` is present."
  def value(acc, opts, key, token) do
    case Keyword.get(opts, key) do
      nil -> acc
      value -> acc ++ [token, value]
    end
  end

  @doc "Appends `[token | values]` to `acc` when `opts[key]` is a non-empty list."
  def list(acc, opts, key, token) do
    case Keyword.get(opts, key) do
      nil -> acc
      [] -> acc
      values -> acc ++ [token | values]
    end
  end

  @doc "Wraps a single term or a list into a list."
  def wrap(term_or_list), do: List.wrap(term_or_list)

  @doc """
  Appends `opts[:usage]`'s wire options (a `HotKV.TokenUsage`, the shared
  "usage group") to `acc`; a no-op when absent. See
  `HotKV.TokenUsage.args/2`.
  """
  def usage(acc, opts), do: HotKV.TokenUsage.args(acc, Keyword.get(opts, :usage))
end
