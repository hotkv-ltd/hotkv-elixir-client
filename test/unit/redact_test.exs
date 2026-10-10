# Copyright (c) 2026 HotKV Ltd
# Licensed under the Apache License, Version 2.0. See LICENSE in the project root.

defmodule HotKV.RedactTest do
  use ExUnit.Case, async: true

  alias HotKV.{Options, TestSupport.FakeServer}

  @secret "s3cr3t-never-log-me"

  test "Options.redact/1 hides the password and the URL userinfo" do
    assert Options.redact(host: "h", password: @secret) == [host: "h", password: "[REDACTED]"]
    assert Options.redact(password: nil) == [password: nil]

    assert Options.redact(url: "hotkvs://user:#{@secret}@h:6579/1") ==
             [url: "hotkvs://[REDACTED]@h:6579/1"]

    assert Options.redact(url: "hotkv://h:6379") == [url: "hotkv://h:6379"]

    {:ok, opts} = Options.new(password: @secret)
    refute inspect(opts) =~ @secret
    assert Options.redact(opts).password == "[REDACTED]"
  end

  test "process status and crash reports never contain the password" do
    {port, _} =
      FakeServer.start(fn
        ["AUTH" | _] -> FakeServer.simple("OK")
        _ -> nil
      end)

    {:ok, conn} = HotKV.start_link(host: "127.0.0.1", port: port, password: @secret)
    refute inspect(:sys.get_status(conn)) =~ @secret

    {:ok, pool} = HotKV.Pool.start_link(host: "127.0.0.1", port: port, password: @secret, size: 1)
    refute inspect(:sys.get_status(pool.pid)) =~ @secret

    {:ok, pubsub} = HotKV.PubSub.start_link(host: "127.0.0.1", port: port, password: @secret)
    refute inspect(:sys.get_status(pubsub)) =~ @secret
  end
end
