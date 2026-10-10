# Copyright (c) 2026 HotKV Ltd
# Licensed under the Apache License, Version 2.0. See LICENSE in the project root.

defmodule HotKV.Options do
  @moduledoc """
  Normalized connection options, built by `new/1` from the keyword list
  passed to `HotKV.start_link/1` (and, when a `:url` is given, from
  `HotKV.URL.parse/1`).

  ## TLS

  `:tls` enables TLS (also implied by a `hotkvs://`/`rediss://` URL).
  `:tls_opts` is a keyword list:

    * `:ca_file` - path to a PEM file of CA certificates to verify the
      server against.
    * `:cert_file` / `:key_file` - client certificate and private key, for
      mutual TLS.
    * `:server_name` - overrides the hostname used for SNI and certificate
      verification (defaults to `:host`).
    * `:insecure_skip_verify` - when `true`, disables server certificate
      verification. For tests only; never enable this in production.
  """

  alias HotKV.{Error, URL}

  # The password never appears in `inspect/1` output (logs, crash reports).
  @derive {Inspect, except: [:password]}
  defstruct host: "127.0.0.1",
            port: 6379,
            unix_socket: nil,
            username: nil,
            password: nil,
            database: 0,
            client_name: nil,
            connect_timeout: 5_000,
            command_timeout: 5_000,
            tls: false,
            tls_opts: [],
            resp3: true,
            socket_opts: []

  @type t :: %__MODULE__{
          host: String.t(),
          port: :inet.port_number(),
          unix_socket: String.t() | nil,
          username: String.t() | nil,
          password: String.t() | nil,
          database: non_neg_integer,
          client_name: String.t() | nil,
          connect_timeout: timeout,
          command_timeout: timeout,
          tls: boolean,
          tls_opts: keyword,
          resp3: boolean,
          socket_opts: [:gen_tcp.connect_option()]
        }

  @keys [
    :host,
    :port,
    :unix_socket,
    :username,
    :password,
    :database,
    :client_name,
    :connect_timeout,
    :command_timeout,
    :tls,
    :tls_opts,
    :resp3,
    :socket_opts
  ]

  @doc """
  Returns a copy of connection options (a keyword list as given to
  `HotKV.start_link/1`, or an `%HotKV.Options{}`) that is safe to log: the
  password is replaced, and so is the userinfo of a `:url`. The processes of
  this library use it in `format_status` so a crash report never prints a
  credential.
  """
  @spec redact(keyword | t | term) :: keyword | t | term
  def redact(%__MODULE__{} = opts), do: %{opts | password: redacted(opts.password)}

  def redact(opts) when is_list(opts) do
    if Keyword.keyword?(opts) do
      opts
      |> Enum.map(fn
        {:password, pw} -> {:password, redacted(pw)}
        {:url, url} when is_binary(url) -> {:url, redact_url(url)}
        other -> other
      end)
    else
      opts
    end
  end

  def redact(other), do: other

  defp redacted(nil), do: nil
  defp redacted(_password), do: "[REDACTED]"

  defp redact_url(url) do
    case String.split(url, "@", parts: 2) do
      [before, rest] ->
        case String.split(before, "://", parts: 2) do
          [scheme, _userinfo] -> scheme <> "://[REDACTED]@" <> rest
          _ -> url
        end

      _ ->
        url
    end
  end

  @doc """
  Builds options from a keyword list. `opts[:url]`, if present, is parsed
  first with `HotKV.URL.parse/1`; every other key in `opts` overrides the
  value the URL produced.
  """
  @spec new(keyword) :: {:ok, t} | {:error, Error.t()}
  def new(opts) when is_list(opts) do
    with {:ok, from_url} <- url_opts(opts) do
      merged = Keyword.merge(from_url, Keyword.delete(opts, :url))
      {:ok, struct(__MODULE__, Keyword.take(merged, @keys))}
    end
  end

  defp url_opts(opts) do
    case Keyword.fetch(opts, :url) do
      {:ok, url} -> URL.parse(url)
      :error -> {:ok, []}
    end
  end
end
