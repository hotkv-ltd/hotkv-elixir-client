# Copyright (c) 2026 HotKV Ltd
# Licensed under the Apache License, Version 2.0. See LICENSE in the project root.

defmodule HotKV.RESP do
  @moduledoc """
  RESP2 and RESP3 wire encoding and decoding.

  `encode/1` turns a list of command arguments into the RESP "array of bulk
  strings" request format every command uses. `decode/1` is a streaming,
  binary-safe parser: it consumes as much of a binary as forms one complete
  reply and returns the unconsumed remainder, so a connection can feed it
  whatever bytes just arrived on the socket without buffering a whole reply
  itself.

  Decoded values use plain Elixir terms:

    * simple string, bulk string, verbatim string -> `binary`
    * integer, big number -> `integer`
    * double -> `float`, or `:inf` / `:"-inf"` / `:nan` for the values the
      BEAM's native float cannot represent
    * boolean -> `true` / `false`
    * null (`$-1`, `*-1`, or RESP3 `_`) -> `nil`
    * array -> `list`
    * map -> `map` (`%{}`)
    * set -> `MapSet`
    * push -> `{:push, list}`
    * simple error, blob error -> `{:resp_error, binary}`
    * attribute -> transparently consumed; decoding continues with the
      reply that follows it

  Only the outermost frame of a reply is ever `{:push, list}` or
  `{:resp_error, binary}`; callers (see `HotKV.Connection`) branch on those
  two shapes and treat everything else as a successful reply value.
  """

  @type value ::
          nil
          | boolean
          | integer
          | float
          | :inf
          | :"-inf"
          | :nan
          | binary
          | list
          | map
          | MapSet.t()
          | {:push, list}
          | {:resp_error, binary}

  @doc """
  Encodes a list of command arguments (binaries, integers, floats or atoms)
  as a RESP multi-bulk request. Returns iodata, ready to hand to `:gen_tcp`
  or `:ssl` directly.

  Argument conversion:

    * a binary is sent byte for byte (binary safe);
    * an integer is sent in decimal;
    * a float is sent as a plain decimal with no exponent, see
      `HotKV.Numeric.format_float/1` (the server's fixed-point parsers
      reject `1.0e-5`);
    * `true` / `false` are sent as `"true"` / `"false"`; any other atom is
      sent as its name (`:inf` / `:"-inf"` as `"inf"` / `"-inf"`, the
      infinite scores sorted-set commands accept).

  Raises `ArgumentError` for `nil`, `:nan` (no HotKV command accepts NaN)
  and any other term that has no wire form (a map, tuple, list, pid, ...),
  so a bad argument is reported to the caller instead of being sent as a
  surprising string.
  """
  @spec encode([binary | integer | float | atom]) :: iodata
  def encode(args) when is_list(args) do
    body = Enum.map(args, &encode_bulk/1)
    [?*, Integer.to_string(length(args)), "\r\n" | body]
  end

  defp encode_bulk(arg) do
    bin = to_binary(arg)
    [?$, Integer.to_string(byte_size(bin)), "\r\n", bin, "\r\n"]
  end

  defp to_binary(arg) when is_binary(arg), do: arg
  defp to_binary(arg) when is_integer(arg), do: Integer.to_string(arg)
  defp to_binary(arg) when is_float(arg), do: HotKV.Numeric.format_float(arg)
  defp to_binary(true), do: "true"
  defp to_binary(false), do: "false"

  defp to_binary(nil) do
    raise ArgumentError, "nil is not a valid HotKV command argument"
  end

  defp to_binary(:nan) do
    raise ArgumentError, "NaN is not a valid HotKV command argument"
  end

  defp to_binary(arg) when is_atom(arg), do: Atom.to_string(arg)

  defp to_binary(arg) do
    raise ArgumentError,
          "cannot encode #{inspect(arg)} as a HotKV command argument " <>
            "(want a binary, integer, float or atom)"
  end

  @doc """
  Decodes one reply from the start of `binary`.

  Returns `{:ok, value, rest}` when a full reply was parsed, `:incomplete`
  when `binary` holds only part of one (the caller should append more bytes
  and try again), or `{:error, {:protocol, reason}}` if `binary` does not
  start with a valid RESP frame.
  """
  @spec decode(binary) :: {:ok, value, binary} | :incomplete | {:error, {:protocol, String.t()}}
  def decode(binary) when is_binary(binary) do
    parse(binary)
  rescue
    e -> {:error, {:protocol, "malformed reply: " <> Exception.message(e)}}
  end

  # -- top-level dispatch --------------------------------------------------

  defp parse(<<>>), do: :incomplete
  defp parse(<<?+, rest::binary>>), do: read_line_as(rest, & &1)
  defp parse(<<?-, rest::binary>>), do: read_line_as(rest, &{:resp_error, &1})
  defp parse(<<?:, rest::binary>>), do: read_line_as(rest, &String.to_integer/1)
  defp parse(<<?(, rest::binary>>), do: read_line_as(rest, &String.to_integer/1)
  defp parse(<<?,, rest::binary>>), do: read_line_as(rest, &parse_double/1)
  defp parse(<<?_, rest::binary>>), do: parse_null3(rest)
  defp parse(<<?#, rest::binary>>), do: parse_boolean(rest)
  defp parse(<<?$, rest::binary>>), do: parse_bulk(rest, :binary)
  defp parse(<<?!, rest::binary>>), do: parse_bulk(rest, :blob_error)
  defp parse(<<?=, rest::binary>>), do: parse_bulk(rest, :verbatim)
  defp parse(<<?*, rest::binary>>), do: parse_aggregate(rest, :array)
  defp parse(<<?~, rest::binary>>), do: parse_aggregate(rest, :set)
  defp parse(<<?>, rest::binary>>), do: parse_aggregate(rest, :push)
  defp parse(<<?%, rest::binary>>), do: parse_map(rest)
  defp parse(<<?|, rest::binary>>), do: parse_attribute(rest)

  defp parse(<<byte, _rest::binary>>) do
    {:error, {:protocol, "unknown reply type byte #{inspect(<<byte>>)}"}}
  end

  # -- line-based scalars ---------------------------------------------------

  defp read_line_as(rest, fun) do
    case read_line(rest) do
      :incomplete -> :incomplete
      {:ok, line, rest2} -> {:ok, fun.(line), rest2}
    end
  end

  defp read_line(bin) do
    case :binary.match(bin, "\r\n") do
      :nomatch ->
        :incomplete

      {pos, _len} ->
        line = binary_part(bin, 0, pos)
        rest = binary_part(bin, pos + 2, byte_size(bin) - pos - 2)
        {:ok, line, rest}
    end
  end

  defp parse_double("inf"), do: :inf
  defp parse_double("+inf"), do: :inf
  defp parse_double("-inf"), do: :"-inf"
  defp parse_double("nan"), do: :nan
  defp parse_double("-nan"), do: :nan

  defp parse_double(text) do
    case Float.parse(text) do
      {f, _rest} -> f
      :error -> text
    end
  end

  defp parse_null3(<<"\r\n", rest::binary>>), do: {:ok, nil, rest}
  defp parse_null3(rest) when byte_size(rest) < 2, do: :incomplete
  defp parse_null3(_rest), do: {:error, {:protocol, "invalid null"}}

  defp parse_boolean(<<?t, "\r\n", rest::binary>>), do: {:ok, true, rest}
  defp parse_boolean(<<?f, "\r\n", rest::binary>>), do: {:ok, false, rest}
  defp parse_boolean(rest) when byte_size(rest) < 3, do: :incomplete
  defp parse_boolean(_rest), do: {:error, {:protocol, "invalid boolean"}}

  # -- length-prefixed byte blobs -------------------------------------------

  defp parse_bulk(rest, kind) do
    case read_line(rest) do
      :incomplete ->
        :incomplete

      {:ok, len_line, after_len} ->
        case Integer.parse(len_line) do
          {-1, ""} ->
            {:ok, nil, after_len}

          {len, ""} when len >= 0 ->
            read_bulk_body(after_len, len, kind)

          _ ->
            {:error, {:protocol, "invalid bulk length: " <> len_line}}
        end
    end
  end

  defp read_bulk_body(bin, len, kind) do
    need = len + 2

    if byte_size(bin) < need do
      :incomplete
    else
      data = binary_part(bin, 0, len)
      rest = binary_part(bin, need, byte_size(bin) - need)
      {:ok, wrap_bulk(kind, data), rest}
    end
  end

  defp wrap_bulk(:binary, data), do: data
  defp wrap_bulk(:blob_error, data), do: {:resp_error, data}

  defp wrap_bulk(:verbatim, <<_format::binary-size(3), ?:, text::binary>>), do: text
  defp wrap_bulk(:verbatim, data), do: data

  # -- aggregates (array, set, push, map, attribute) ------------------------

  defp parse_aggregate(rest, kind) do
    case read_line(rest) do
      :incomplete ->
        :incomplete

      {:ok, len_line, after_len} ->
        case Integer.parse(len_line) do
          {-1, ""} -> {:ok, wrap_aggregate(kind, nil), after_len}
          {n, ""} when n >= 0 -> parse_items(after_len, n, [], kind)
          _ -> {:error, {:protocol, "invalid aggregate length: " <> len_line}}
        end
    end
  end

  defp parse_items(rest, 0, acc, kind), do: {:ok, wrap_aggregate(kind, Enum.reverse(acc)), rest}

  defp parse_items(rest, n, acc, kind) do
    case parse(rest) do
      {:ok, value, rest2} -> parse_items(rest2, n - 1, [value | acc], kind)
      :incomplete -> :incomplete
      {:error, _} = err -> err
    end
  end

  defp wrap_aggregate(:array, list), do: list
  defp wrap_aggregate(:set, nil), do: MapSet.new()
  defp wrap_aggregate(:set, list), do: MapSet.new(list)
  defp wrap_aggregate(:push, nil), do: {:push, []}
  defp wrap_aggregate(:push, list), do: {:push, list}

  defp parse_map(rest) do
    case read_line(rest) do
      :incomplete ->
        :incomplete

      {:ok, len_line, after_len} ->
        case Integer.parse(len_line) do
          {-1, ""} -> {:ok, nil, after_len}
          {n, ""} when n >= 0 -> parse_pairs(after_len, n, [])
          _ -> {:error, {:protocol, "invalid map length: " <> len_line}}
        end
    end
  end

  defp parse_pairs(rest, 0, acc), do: {:ok, Map.new(acc), rest}

  defp parse_pairs(rest, n, acc) do
    with {:ok, k, rest2} <- parse(rest),
         {:ok, v, rest3} <- parse(rest2) do
      parse_pairs(rest3, n - 1, [{k, v} | acc])
    else
      :incomplete -> :incomplete
      {:error, _} = err -> err
    end
  end

  # An attribute reply precedes, and describes, the actual reply that
  # follows it. Clients that do not surface attributes to callers (this one
  # included) parse and discard the attribute map, then return the reply
  # that comes right after it.
  defp parse_attribute(rest) do
    case parse_map(rest) do
      {:ok, _attributes, rest2} -> parse(rest2)
      :incomplete -> :incomplete
      {:error, _} = err -> err
    end
  end
end
