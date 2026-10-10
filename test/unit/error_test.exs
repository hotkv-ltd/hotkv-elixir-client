# Copyright (c) 2026 HotKV Ltd
# Licensed under the Apache License, Version 2.0. See LICENSE in the project root.

defmodule HotKV.ErrorTest do
  use ExUnit.Case, async: true

  alias HotKV.Error

  test "server/1 extracts the leading token as :prefix and kind :server" do
    error = Error.server("WRONGTYPE Operation against a key holding the wrong kind of value")
    assert error.kind == :server
    assert error.prefix == "WRONGTYPE"
    assert Error.wrong_type?(error)
  end

  test "server/1 recognizes NOLICENSE as its own kind" do
    error = Error.server("NOLICENSE enterprise feature 'prompt-cache' requires a valid license")
    assert error.kind == :not_licensed
    assert error.prefix == "NOLICENSE"
    assert Error.not_licensed?(error)
    refute Error.not_licensed?(Error.server("ERR something else"))
  end

  test "cluster_redirect/1 parses MOVED" do
    error = Error.cluster_redirect("MOVED 3999 127.0.0.1:6381")
    assert error.kind == :cluster_redirect
    assert Error.cluster_redirect?(error)
    assert error.redirect == %{type: :moved, slot: 3999, host: "127.0.0.1", port: 6381}
  end

  test "cluster_redirect/1 parses ASK" do
    error = Error.cluster_redirect("ASK 3999 127.0.0.1:6381")
    assert error.redirect.type == :ask
    assert error.redirect.slot == 3999
    assert error.redirect.host == "127.0.0.1"
    assert error.redirect.port == 6381
  end

  test "is a proper Exception: message/1 and raise/1 work" do
    error = Error.timeout("took too long")
    assert Exception.message(error) == "took too long"

    assert_raise HotKV.Error, "took too long", fn -> raise error end
  end

  test "HotKV.bang!/1 unwraps :ok and raises the error from :error" do
    assert HotKV.bang!({:ok, 42}) == 42
    assert_raise HotKV.Error, fn -> HotKV.bang!({:error, Error.connection("down")}) end
  end
end
