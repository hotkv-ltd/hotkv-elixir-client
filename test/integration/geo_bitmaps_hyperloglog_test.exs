# Copyright (c) 2026 HotKV Ltd
# Licensed under the Apache License, Version 2.0. See LICENSE in the project root.

defmodule HotKV.GeoBitmapsHyperLogLogIntegrationTest do
  use ExUnit.Case, async: true
  @moduletag :integration

  alias HotKV.{Bitmaps, Geo, HyperLogLog, TestSupport}

  setup do
    conn = TestSupport.start_conn()
    k = TestSupport.unique("geobits")
    on_exit(fn -> HotKV.command(conn, ["DEL", k, k <> ":2", k <> ":dest"]) end)
    {:ok, conn: conn, k: k}
  end

  describe "Geo" do
    test "GEOADD/GEOPOS/GEODIST/GEOHASH", %{conn: conn, k: k} do
      assert {:ok, 2} =
               Geo.geoadd(conn, k, [
                 {13.361389, 38.115556, "Palermo"},
                 {15.087269, 37.502669, "Catania"}
               ])

      assert {:ok, [{lon, lat}, nil]} = Geo.geopos(conn, k, ["Palermo", "missing"])
      assert_in_delta lon, 13.361389, 0.001
      assert_in_delta lat, 38.115556, 0.001

      assert {:ok, dist} = Geo.geodist(conn, k, "Palermo", "Catania", :km)
      assert_in_delta dist, 166.27, 1.0

      assert {:ok, [hash, nil]} = Geo.geohash(conn, k, ["Palermo", "missing"])
      assert is_binary(hash)
    end

    test "GEOSEARCH by member and by box, with WITH* flags", %{conn: conn, k: k} do
      Geo.geoadd(conn, k, [{13.361389, 38.115556, "Palermo"}, {15.087269, 37.502669, "Catania"}])

      assert {:ok, ["Palermo", "Catania"]} =
               Geo.geosearch(conn, k, from_member: "Palermo", by_radius: {200, :km}, order: :asc)

      assert {:ok, [%{member: "Palermo", distance: dist} | _]} =
               Geo.geosearch(conn, k,
                 from_member: "Palermo",
                 by_radius: {200, :km},
                 order: :asc,
                 withdist: true
               )

      assert_in_delta dist, 0.0, 0.01
    end

    test "GEOSEARCHSTORE", %{conn: conn, k: k} do
      dest = k <> ":dest"
      Geo.geoadd(conn, k, [{13.361389, 38.115556, "Palermo"}])

      assert {:ok, 1} =
               Geo.geosearchstore(conn, dest, k, from_member: "Palermo", by_radius: {10, :km})

      HotKV.command(conn, ["DEL", dest])
    end
  end

  describe "Bitmaps" do
    test "SETBIT/GETBIT/BITCOUNT/BITPOS/BITOP", %{conn: conn, k: k} do
      k2 = k <> ":2"
      assert {:ok, 0} = Bitmaps.setbit(conn, k, 7, 1)
      assert {:ok, 1} = Bitmaps.getbit(conn, k, 7)
      assert {:ok, 1} = Bitmaps.bitcount(conn, k)
      assert {:ok, 7} = Bitmaps.bitpos(conn, k, 1)

      Bitmaps.setbit(conn, k2, 0, 1)
      assert {:ok, _len} = Bitmaps.bitop(conn, :and, k <> ":dest", [k, k2])
    end

    test "BITFIELD", %{conn: conn, k: k} do
      assert {:ok, [1, 1]} =
               Bitmaps.bitfield(conn, k, ["INCRBY", "u8", "0", "1", "GET", "u8", "0"])
    end
  end

  describe "HyperLogLog" do
    test "PFADD/PFCOUNT/PFMERGE", %{conn: conn, k: k} do
      k2 = k <> ":2"
      assert {:ok, true} = HyperLogLog.pfadd(conn, k, ["a", "b", "c"])
      assert {:ok, false} = HyperLogLog.pfadd(conn, k, ["a"])
      assert {:ok, count} = HyperLogLog.pfcount(conn, k)
      assert count >= 2 and count <= 4

      HyperLogLog.pfadd(conn, k2, ["c", "d"])
      assert {:ok, "OK"} = HyperLogLog.pfmerge(conn, k <> ":dest", [k, k2])
      HotKV.command(conn, ["DEL", k <> ":dest"])
    end
  end
end
