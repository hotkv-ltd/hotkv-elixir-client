# Copyright (c) 2026 HotKV Ltd
# Licensed under the Apache License, Version 2.0. See LICENSE in the project root.

defmodule HotKV.RESPTest do
  use ExUnit.Case, async: true

  alias HotKV.RESP

  describe "encode/1" do
    test "builds a RESP multi-bulk request" do
      assert IO.iodata_to_binary(RESP.encode(["SET", "k", "v"])) ==
               "*3\r\n$3\r\nSET\r\n$1\r\nk\r\n$1\r\nv\r\n"
    end

    test "converts integers, floats and atoms to their string form" do
      assert IO.iodata_to_binary(RESP.encode(["INCRBY", "k", 42])) ==
               "*3\r\n$6\r\nINCRBY\r\n$1\r\nk\r\n$2\r\n42\r\n"

      assert IO.iodata_to_binary(RESP.encode([1.5])) == "*1\r\n$3\r\n1.5\r\n"
      assert IO.iodata_to_binary(RESP.encode([:nx])) == "*1\r\n$2\r\nnx\r\n"
    end

    test "is binary safe" do
      bin = <<0, 1, 2, "\r\n", 255>>
      encoded = IO.iodata_to_binary(RESP.encode([bin]))
      assert encoded == "*1\r\n$#{byte_size(bin)}\r\n#{bin}\r\n"
    end
  end

  describe "decode/1 - RESP2" do
    test "simple string" do
      assert RESP.decode("+OK\r\n") == {:ok, "OK", ""}
    end

    test "error" do
      assert RESP.decode("-ERR bad thing\r\n") == {:ok, {:resp_error, "ERR bad thing"}, ""}
    end

    test "integer" do
      assert RESP.decode(":1000\r\n") == {:ok, 1000, ""}
      assert RESP.decode(":-1\r\n") == {:ok, -1, ""}
    end

    test "bulk string, including binary-safe content with embedded CRLF" do
      assert RESP.decode("$5\r\nhello\r\n") == {:ok, "hello", ""}
      assert RESP.decode("$5\r\na\r\nb\x00\r\n") == {:ok, "a\r\nb\x00", ""}
    end

    test "null bulk string maps to nil" do
      assert RESP.decode("$-1\r\n") == {:ok, nil, ""}
    end

    test "array and nested array" do
      assert RESP.decode("*2\r\n$1\r\na\r\n$1\r\nb\r\n") == {:ok, ["a", "b"], ""}
      assert RESP.decode("*1\r\n*2\r\n:1\r\n:2\r\n") == {:ok, [[1, 2]], ""}
    end

    test "null array maps to nil" do
      assert RESP.decode("*-1\r\n") == {:ok, nil, ""}
    end

    test "empty array" do
      assert RESP.decode("*0\r\n") == {:ok, [], ""}
    end
  end

  describe "decode/1 - RESP3" do
    test "null" do
      assert RESP.decode("_\r\n") == {:ok, nil, ""}
    end

    test "boolean" do
      assert RESP.decode("#t\r\n") == {:ok, true, ""}
      assert RESP.decode("#f\r\n") == {:ok, false, ""}
    end

    test "double, including integer-looking, inf, -inf and nan" do
      assert RESP.decode(",3.14\r\n") == {:ok, 3.14, ""}
      assert RESP.decode(",3\r\n") == {:ok, 3.0, ""}
      assert RESP.decode(",inf\r\n") == {:ok, :inf, ""}
      assert RESP.decode(",-inf\r\n") == {:ok, :"-inf", ""}
      assert RESP.decode(",nan\r\n") == {:ok, :nan, ""}
    end

    test "big number (arbitrary precision, native Elixir integer)" do
      assert RESP.decode("(3492890328409238509324850943850943825024385\r\n") ==
               {:ok, 3_492_890_328_409_238_509_324_850_943_850_943_825_024_385, ""}
    end

    test "blob error" do
      assert RESP.decode("!18\r\nSYNTAX invalid arg\r\n") ==
               {:ok, {:resp_error, "SYNTAX invalid arg"}, ""}
    end

    test "verbatim string" do
      assert RESP.decode("=15\r\ntxt:Some string\r\n") == {:ok, "Some string", ""}
    end

    test "map decodes to a native Elixir map" do
      assert RESP.decode("%2\r\n$1\r\na\r\n:1\r\n$1\r\nb\r\n:2\r\n") ==
               {:ok, %{"a" => 1, "b" => 2}, ""}
    end

    test "set decodes to a MapSet" do
      assert RESP.decode("~2\r\n$1\r\na\r\n$1\r\nb\r\n") == {:ok, MapSet.new(["a", "b"]), ""}
    end

    test "push is tagged distinctly from a plain array" do
      assert RESP.decode(">2\r\n$1\r\na\r\n$1\r\nb\r\n") == {:ok, {:push, ["a", "b"]}, ""}
    end

    test "attribute is consumed transparently, returning the reply that follows it" do
      assert RESP.decode("|1\r\n$8\r\nkey-hits\r\n:1\r\n$3\r\nfoo\r\n") == {:ok, "foo", ""}
    end
  end

  describe "decode/1 - streaming" do
    test "reports :incomplete until a full reply has arrived, byte by byte" do
      full = "$5\r\nhello\r\n"

      final =
        Enum.reduce(0..(byte_size(full) - 1), <<>>, fn i, buffer ->
          chunk = binary_part(full, i, 1)

          case RESP.decode(buffer <> chunk) do
            :incomplete -> buffer <> chunk
            {:ok, "hello", ""} -> buffer <> chunk
          end
        end)

      assert RESP.decode(final) == {:ok, "hello", ""}
    end

    test "leaves a second reply already in the buffer as the returned rest" do
      assert RESP.decode("+OK\r\n:1\r\n") == {:ok, "OK", ":1\r\n"}
    end
  end

  describe "decode/1 - errors" do
    test "unknown type byte is a protocol error, not a crash" do
      assert {:error, {:protocol, _reason}} = RESP.decode("?nonsense\r\n")
    end
  end
end
