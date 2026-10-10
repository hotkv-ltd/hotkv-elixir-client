# Copyright (c) 2026 HotKV Ltd
# Licensed under the Apache License, Version 2.0. See LICENSE in the project root.

defmodule HotKV.Transport do
  @moduledoc false
  # Socket-level mechanics shared by HotKV.Connection and HotKV.PubSub:
  # opening a TCP/TLS/unix socket, the HELLO/AUTH/SELECT handshake (run
  # synchronously in passive mode), and switching to `active: :once` for the
  # caller's own receive loop.

  alias HotKV.{Error, Options, RESP}

  @type transport :: :gen_tcp | :ssl
  @type socket :: :gen_tcp.socket() | :ssl.sslsocket()

  @doc """
  Opens a connection per `opts`, performs the HELLO/AUTH/SELECT handshake,
  and arms the socket for asynchronous delivery (`active: :once`).

  Returns `{:ok, transport, socket, resp3?, leftover}`, where `leftover` is
  any bytes read past the handshake's own replies (normally empty) that the
  caller's receive loop must treat as already-buffered input.
  """
  @spec connect(Options.t()) ::
          {:ok, transport, socket, boolean, binary} | {:error, Error.t()}
  def connect(%Options{} = opts) do
    with {:ok, transport, socket} <- open_socket(opts),
         {:ok, resp3, leftover} <- handshake(transport, socket, opts),
         :ok <- arm(transport, socket) do
      {:ok, transport, socket, resp3, leftover}
    else
      {:error, _} = err ->
        err
    end
  end

  @doc "Sends `iodata` on `socket`."
  @spec send(transport, socket, iodata) :: :ok | {:error, Error.t()}
  def send(:gen_tcp, socket, iodata), do: wrap_send(:gen_tcp.send(socket, iodata))
  def send(:ssl, socket, iodata), do: wrap_send(:ssl.send(socket, iodata))

  defp wrap_send(:ok), do: :ok

  defp wrap_send({:error, reason}),
    do: {:error, Error.connection("send failed: #{inspect(reason)}")}

  @doc "Re-arms `socket` for one more `active` message after each delivery."
  @spec arm(transport, socket) :: :ok | {:error, Error.t()}
  def arm(:gen_tcp, socket) do
    case :inet.setopts(socket, active: :once) do
      :ok -> :ok
      {:error, reason} -> {:error, Error.connection("setopts failed: #{inspect(reason)}")}
    end
  end

  def arm(:ssl, socket) do
    case :ssl.setopts(socket, active: :once) do
      :ok -> :ok
      {:error, reason} -> {:error, Error.connection("setopts failed: #{inspect(reason)}")}
    end
  end

  @doc "Closes `socket`, ignoring errors (the connection is going away regardless)."
  @spec close(transport, socket) :: :ok
  def close(:gen_tcp, socket), do: :gen_tcp.close(socket)
  def close(:ssl, socket), do: :ssl.close(socket)

  # -- connecting -------------------------------------------------------

  defp open_socket(%Options{unix_socket: path} = opts) when is_binary(path) do
    sock_opts = [:binary, active: false, packet: :raw] ++ opts.socket_opts

    case :gen_tcp.connect({:local, String.to_charlist(path)}, 0, sock_opts, opts.connect_timeout) do
      {:ok, socket} ->
        {:ok, :gen_tcp, socket}

      {:error, reason} ->
        {:error, Error.connection("unix socket connect failed: #{inspect(reason)}")}
    end
  end

  defp open_socket(%Options{tls: false} = opts) do
    sock_opts = [:binary, active: false, packet: :raw] ++ opts.socket_opts

    case :gen_tcp.connect(
           String.to_charlist(opts.host),
           opts.port,
           sock_opts,
           opts.connect_timeout
         ) do
      {:ok, socket} -> {:ok, :gen_tcp, socket}
      {:error, reason} -> {:error, Error.connection("connect failed: #{inspect(reason)}")}
    end
  end

  defp open_socket(%Options{tls: true} = opts) do
    with {:ok, tls} <- build_ssl_opts(opts) do
      ssl_opts = [:binary, active: false, packet: :raw] ++ tls ++ opts.socket_opts

      case :ssl.connect(String.to_charlist(opts.host), opts.port, ssl_opts, opts.connect_timeout) do
        {:ok, socket} -> {:ok, :ssl, socket}
        {:error, reason} -> {:error, Error.connection("TLS connect failed: #{inspect(reason)}")}
      end
    end
  end

  defp build_ssl_opts(%Options{host: host, tls_opts: tls_opts}) do
    reference = Keyword.get(tls_opts, :server_name, host)
    ref_id = reference_id(reference)

    # SNI carries host names only: for an IP address it is switched off and
    # the address is checked against the certificate by verify_peer/3.
    sni =
      case ref_id do
        {:ip, _} -> :disable
        {:dns_id, name} -> name
      end

    with {:ok, verify_opts} <- verify_opts(tls_opts, ref_id) do
      cert_opts =
        case {Keyword.get(tls_opts, :cert_file), Keyword.get(tls_opts, :key_file)} do
          {nil, nil} -> []
          {cert, key} -> [certfile: String.to_charlist(cert), keyfile: String.to_charlist(key)]
        end

      {:ok, [server_name_indication: sni] ++ verify_opts ++ cert_opts}
    end
  end

  defp reference_id(reference) do
    charlist = String.to_charlist(reference)

    case :inet.parse_address(charlist) do
      {:ok, ip} -> {:ip, ip}
      {:error, _} -> {:dns_id, charlist}
    end
  end

  defp verify_opts(tls_opts, ref_id) do
    if Keyword.get(tls_opts, :insecure_skip_verify, false) do
      {:ok, [verify: :verify_none]}
    else
      with {:ok, cacert_opts, ders} <- cacert_opts(tls_opts) do
        verify_fun = {&__MODULE__.verify_peer/3, %{ders: ders, ref: ref_id}}
        {:ok, [verify: :verify_peer, depth: 4, verify_fun: verify_fun] ++ cacert_opts}
      end
    end
  end

  defp cacert_opts(tls_opts) do
    case Keyword.get(tls_opts, :ca_file) do
      nil ->
        with {:ok, opts} <- system_cacerts(), do: {:ok, opts, []}

      path ->
        {:ok, [cacertfile: String.to_charlist(path)], pem_certificates(path)}
    end
  end

  defp pem_certificates(path) do
    case File.read(path) do
      {:ok, pem} ->
        for {:Certificate, der, :not_encrypted} <- :public_key.pem_decode(pem), do: der

      {:error, _} ->
        []
    end
  end

  # Certificate path verification, called by OTP for each certificate.
  #
  #   * OTP rejects a server certificate that is self-signed even when that
  #     very certificate is the file given as :ca_file ({:bad_cert,
  #     :selfsigned_peer}), which is how a self-signed server is normally
  #     trusted. That one case is accepted when the peer certificate is byte
  #     for byte one of the certificates in the CA file.
  #   * The server name is verified here against the certificate's subject
  #     alternative names (a DNS name, or an IP address, which OTP's own
  #     check does not support), so the check also covers the case above.
  #   * Every other failure fails the handshake, as with the default.
  @doc false
  def verify_peer(cert, {:bad_cert, :selfsigned_peer} = reason, %{ders: ders, ref: ref} = state) do
    # OTP does not report :valid_peer for a certificate accepted here, so the
    # server name is checked now.
    if cert_der(cert) in ders and hostname_ok?(cert, ref),
      do: {:valid, state},
      else: {:fail, reason}
  end

  def verify_peer(_cert, {:bad_cert, _} = reason, _state), do: {:fail, reason}
  def verify_peer(_cert, {:extension, _}, state), do: {:unknown, state}
  def verify_peer(_cert, :valid, state), do: {:valid, state}

  def verify_peer(cert, :valid_peer, %{ref: ref} = state) do
    if hostname_ok?(cert, ref),
      do: {:valid, state},
      else: {:fail, {:bad_cert, :hostname_check_failed}}
  end

  defp hostname_ok?(cert, ref), do: :public_key.pkix_verify_hostname(cert, [ref])

  defp cert_der(der) when is_binary(der), do: der
  defp cert_der(otp_cert), do: :public_key.pkix_encode(:OTPCertificate, otp_cert, :otp)

  # The operating system's trust store is read with :public_key.cacerts_get/0,
  # which exists from OTP 25. On OTP 24 a CA file must be given instead.
  defp system_cacerts do
    if Code.ensure_loaded?(:public_key) and function_exported?(:public_key, :cacerts_get, 0) do
      {:ok, [cacerts: :public_key.cacerts_get()]}
    else
      {:error,
       Error.connection(
         "TLS server verification without tls_opts[:ca_file] needs OTP 25 or newer " <>
           "(it reads the system CA store); pass tls_opts: [ca_file: path] on this OTP release"
       )}
    end
  end

  # -- handshake (HELLO 3, with fallback to legacy AUTH/SELECT) ---------

  # `resp3: false` skips HELLO entirely: plain RESP2 with AUTH/SETNAME/SELECT.
  defp handshake(transport, socket, %Options{resp3: false} = opts),
    do: legacy_handshake(transport, socket, opts, <<>>)

  defp handshake(transport, socket, opts) do
    case request(transport, socket, hello_args(3, opts), <<>>, opts.connect_timeout) do
      {:ok, %{}, leftover} ->
        post_hello(transport, socket, opts, true, leftover)

      {:ok, list, leftover} when is_list(list) ->
        post_hello(transport, socket, opts, true, leftover)

      {:ok, {:resp_error, message}, leftover} ->
        if fallback_to_resp2?(message) do
          legacy_handshake(transport, socket, opts, leftover)
        else
          {:error, Error.server(message)}
        end

      {:error, _} = err ->
        err
    end
  end

  # Any reply other than a straightforward error means HELLO worked, so this
  # only inspects the error case: an old (pre-HELLO) server, or one that
  # rejects protocol 3, falls back; anything else (bad password, ACL denial)
  # is a real, fatal connection error and must not be masked by a retry.
  defp fallback_to_resp2?(message) do
    upcased = String.upcase(message)

    String.starts_with?(upcased, "NOPROTO") or
      String.contains?(upcased, "UNKNOWN COMMAND") or
      String.contains?(upcased, "UNKNOWN SUBCOMMAND")
  end

  defp post_hello(transport, socket, opts, resp3, leftover) do
    with {:ok, leftover} <- maybe_select(transport, socket, opts, leftover) do
      {:ok, resp3, leftover}
    end
  end

  defp legacy_handshake(transport, socket, opts, leftover) do
    with {:ok, leftover} <- maybe_auth(transport, socket, opts, leftover),
         {:ok, leftover} <- maybe_setname(transport, socket, opts, leftover),
         {:ok, leftover} <- maybe_select(transport, socket, opts, leftover) do
      {:ok, false, leftover}
    end
  end

  defp maybe_auth(_transport, _socket, %Options{password: nil}, leftover), do: {:ok, leftover}

  defp maybe_auth(transport, socket, opts, leftover) do
    args =
      if opts.username, do: ["AUTH", opts.username, opts.password], else: ["AUTH", opts.password]

    expect_ok(transport, socket, args, leftover, opts.connect_timeout)
  end

  defp maybe_setname(_transport, _socket, %Options{client_name: nil}, leftover),
    do: {:ok, leftover}

  defp maybe_setname(transport, socket, opts, leftover) do
    expect_ok(
      transport,
      socket,
      ["CLIENT", "SETNAME", opts.client_name],
      leftover,
      opts.connect_timeout
    )
  end

  defp maybe_select(_transport, _socket, %Options{database: 0}, leftover), do: {:ok, leftover}

  defp maybe_select(transport, socket, opts, leftover) do
    expect_ok(
      transport,
      socket,
      ["SELECT", Integer.to_string(opts.database)],
      leftover,
      opts.connect_timeout
    )
  end

  defp expect_ok(transport, socket, args, leftover, timeout) do
    case request(transport, socket, args, leftover, timeout) do
      {:ok, {:resp_error, message}, _leftover} -> {:error, Error.server(message)}
      {:ok, _value, leftover} -> {:ok, leftover}
      {:error, _} = err -> err
    end
  end

  defp hello_args(proto, opts) do
    ["HELLO", Integer.to_string(proto)] ++ auth_args(opts) ++ setname_args(opts)
  end

  defp auth_args(%Options{password: nil}), do: []
  defp auth_args(%Options{username: nil, password: password}), do: ["AUTH", "default", password]

  defp auth_args(%Options{username: username, password: password}),
    do: ["AUTH", username, password]

  defp setname_args(%Options{client_name: nil}), do: []
  defp setname_args(%Options{client_name: name}), do: ["SETNAME", name]

  # Sends one request and blocks (in passive mode) until exactly one full
  # reply has been parsed, returning any bytes read past it.
  defp request(transport, socket, args, buffer, timeout) do
    with :ok <- send(transport, socket, RESP.encode(args)) do
      recv_reply(transport, socket, buffer, timeout)
    end
  end

  defp recv_reply(transport, socket, buffer, timeout) do
    case RESP.decode(buffer) do
      {:ok, value, rest} ->
        {:ok, value, rest}

      :incomplete ->
        case recv(transport, socket, timeout) do
          {:ok, data} -> recv_reply(transport, socket, buffer <> data, timeout)
          {:error, _} = err -> err
        end

      {:error, {:protocol, reason}} ->
        {:error, Error.protocol(reason)}
    end
  end

  defp recv(:gen_tcp, socket, timeout) do
    case :gen_tcp.recv(socket, 0, timeout) do
      {:ok, data} -> {:ok, data}
      {:error, reason} -> {:error, Error.connection("recv failed: #{inspect(reason)}")}
    end
  end

  defp recv(:ssl, socket, timeout) do
    case :ssl.recv(socket, 0, timeout) do
      {:ok, data} -> {:ok, data}
      {:error, reason} -> {:error, Error.connection("recv failed: #{inspect(reason)}")}
    end
  end
end
