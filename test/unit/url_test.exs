# Copyright (c) 2026 HotKV Ltd
# Licensed under the Apache License, Version 2.0. See LICENSE in the project root.

defmodule HotKV.URLTest do
  use ExUnit.Case, async: true

  alias HotKV.URL

  test "hotkv:// parses host, port and defaults tls off" do
    assert {:ok, opts} = URL.parse("hotkv://example.com:6400")
    assert opts[:host] == "example.com"
    assert opts[:port] == 6400
    assert opts[:tls] == false
  end

  test "hotkvs:// enables tls" do
    assert {:ok, opts} = URL.parse("hotkvs://example.com:6400")
    assert opts[:tls] == true
  end

  test "redis:// and rediss:// are accepted as aliases" do
    assert {:ok, opts} = URL.parse("redis://example.com")
    assert opts[:tls] == false
    assert {:ok, opts} = URL.parse("rediss://example.com")
    assert opts[:tls] == true
  end

  test "missing host defaults to 127.0.0.1, missing port defaults to 6379" do
    assert {:ok, opts} = URL.parse("hotkv://")
    assert opts[:host] == "127.0.0.1"
    assert opts[:port] == 6379
  end

  test "username and password from userinfo" do
    assert {:ok, opts} = URL.parse("hotkv://alice:s3cret@host:1234")
    assert opts[:username] == "alice"
    assert opts[:password] == "s3cret"
  end

  test "a single userinfo component with no colon is a legacy password-only AUTH" do
    assert {:ok, opts} = URL.parse("hotkv://s3cret@host")
    assert opts[:username] == nil
    assert opts[:password] == "s3cret"
  end

  test "an empty username (redis://:secret@host) is the password-only form" do
    assert {:ok, opts} = URL.parse("redis://:s3cret@host:1234")
    refute Keyword.has_key?(opts, :username)
    assert opts[:password] == "s3cret"
  end

  test "userinfo is split before it is percent-decoded" do
    assert {:ok, opts} = URL.parse("hotkv://al%40ice:p%3Ass%2Fw@host")
    assert opts[:username] == "al@ice"
    assert opts[:password] == "p:ss/w"

    assert {:ok, opts} = URL.parse("hotkv://p%3Ass@host")
    refute Keyword.has_key?(opts, :username)
    assert opts[:password] == "p:ss"
  end

  test "database index from the path" do
    assert {:ok, opts} = URL.parse("hotkv://host/3")
    assert opts[:database] == 3
  end

  test "no path means no database override" do
    assert {:ok, opts} = URL.parse("hotkv://host")
    refute Keyword.has_key?(opts, :database)
  end

  test "invalid database index is an error" do
    assert {:error, %HotKV.Error{kind: :connection}} = URL.parse("hotkv://host/notanumber")
  end

  test "unsupported scheme is an error" do
    assert {:error, %HotKV.Error{kind: :connection}} = URL.parse("ftp://host")
  end

  test "unix:// parses the socket path and an optional database query parameter" do
    assert {:ok, opts} = URL.parse("unix:///tmp/hotkv.sock")
    assert opts[:unix_socket] == "/tmp/hotkv.sock"

    assert {:ok, opts} = URL.parse("unix:///tmp/hotkv.sock?database=2")
    assert opts[:database] == 2
  end
end
