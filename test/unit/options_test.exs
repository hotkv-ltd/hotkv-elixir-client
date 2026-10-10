# Copyright (c) 2026 HotKV Ltd
# Licensed under the Apache License, Version 2.0. See LICENSE in the project root.

defmodule HotKV.OptionsTest do
  use ExUnit.Case, async: true

  alias HotKV.Options

  test "defaults" do
    assert {:ok, opts} = Options.new([])
    assert opts.host == "127.0.0.1"
    assert opts.port == 6379
    assert opts.database == 0
    assert opts.resp3 == true
    assert opts.tls == false
  end

  test "explicit keys are used directly, without a url" do
    assert {:ok, opts} = Options.new(host: "db.internal", port: 6400, password: "secret")
    assert opts.host == "db.internal"
    assert opts.port == 6400
    assert opts.password == "secret"
  end

  test "a url is parsed first, and explicit keys override what it produced" do
    assert {:ok, opts} = Options.new(url: "hotkv://user:pass@example.com:6400/2", database: 5)
    assert opts.host == "example.com"
    assert opts.port == 6400
    assert opts.username == "user"
    assert opts.password == "pass"
    # explicit :database overrides the /2 the URL carried
    assert opts.database == 5
  end

  test "an invalid url surfaces as an error instead of building options" do
    assert {:error, %HotKV.Error{}} = Options.new(url: "hotkv://host/notanumber")
  end

  test "unknown keys are ignored rather than raising" do
    assert {:ok, %Options{}} = Options.new(totally_unknown_option: true)
  end
end
