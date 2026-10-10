# Copyright (c) 2026 HotKV Ltd
# Licensed under the Apache License, Version 2.0. See LICENSE in the project root.

defmodule HotKV.URL do
  @moduledoc """
  Parses HotKV connection URLs into the keyword list `HotKV.Options.new/1`
  understands.

  Supported forms:

    * `hotkv://[username:password@]host[:port][/database]`
    * `hotkvs://...` - same, with TLS enabled
    * `redis://...` / `rediss://...` - accepted for drop-in migration,
      behave exactly like `hotkv://` / `hotkvs://`
    * `unix:///path/to/socket[?database=N]`

  A bare userinfo component with no colon (`hotkv://secret@host`) is treated
  as the legacy single-value `AUTH secret` form.
  """

  alias HotKV.Error

  @default_port 6379

  @doc """
  Parses `url` into a keyword list of options suitable for
  `HotKV.Options.new/1` (and therefore for `HotKV.start_link/1`).
  """
  @spec parse(String.t()) :: {:ok, keyword} | {:error, Error.t()}
  def parse(url) when is_binary(url) do
    case URI.new(url) do
      {:ok, uri} -> from_uri(uri)
      {:error, reason} -> {:error, Error.connection("invalid HotKV URL: #{inspect(reason)}")}
    end
  end

  defp from_uri(%URI{scheme: scheme} = uri) when scheme in ~w(hotkv redis) do
    build(uri, tls: false)
  end

  defp from_uri(%URI{scheme: scheme} = uri) when scheme in ~w(hotkvs rediss) do
    build(uri, tls: true)
  end

  defp from_uri(%URI{scheme: "unix", path: path} = uri) when is_binary(path) and path != "" do
    with {:ok, db_opts} <- query_database_opts(uri) do
      {:ok, [unix_socket: path, tls: false] ++ db_opts}
    end
  end

  defp from_uri(%URI{scheme: scheme}) do
    {:error,
     Error.connection(
       "unsupported HotKV URL scheme #{inspect(scheme)} " <>
         "(want hotkv, hotkvs, redis, rediss or unix)"
     )}
  end

  defp build(%URI{host: host, port: port} = uri, extra) do
    host = if host in [nil, ""], do: "127.0.0.1", else: host

    with {:ok, db_opts} <- path_database_opts(uri) do
      {:ok, extra ++ [host: host, port: port || @default_port] ++ userinfo_opts(uri) ++ db_opts}
    end
  end

  defp userinfo_opts(%URI{userinfo: nil}), do: []

  defp userinfo_opts(%URI{userinfo: userinfo}) do
    # Split on the first literal ":" and only then percent-decode each half,
    # so an encoded colon (%3A) inside a password stays part of it.
    case String.split(userinfo, ":", parts: 2) do
      [""] ->
        []

      [username, password] when username != "" ->
        [username: decode(username), password: decode(password)]

      # "redis://:secret@host": an empty username is the password-only form.
      ["", password] when password != "" ->
        [password: decode(password)]

      [password] ->
        [password: decode(password)]

      _ ->
        []
    end
  end

  defp decode(text), do: URI.decode(text)

  defp path_database_opts(%URI{path: path}) when is_binary(path) do
    case String.trim_leading(path, "/") do
      "" -> {:ok, []}
      digits -> parse_database(digits)
    end
  end

  defp path_database_opts(_uri), do: {:ok, []}

  defp query_database_opts(%URI{query: nil}), do: {:ok, []}

  defp query_database_opts(%URI{query: query}) do
    case URI.decode_query(query) do
      %{"database" => digits} -> parse_database(digits)
      %{"db" => digits} -> parse_database(digits)
      _ -> {:ok, []}
    end
  end

  defp parse_database(digits) do
    case Integer.parse(digits) do
      {db, ""} -> {:ok, [database: db]}
      _ -> {:error, Error.connection("invalid database index in URL: #{inspect(digits)}")}
    end
  end
end
