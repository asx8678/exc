defmodule CodePuppyControl.RateLimiter.BucketTest do
  use ExUnit.Case, async: false

  alias CodePuppyControl.RateLimiter.Bucket

  setup do
    if :ets.info(Bucket.table()) == :undefined do
      Bucket.create_table()
    end

    Bucket.clear()
    :ok
  end

  describe "init_bucket/3" do
    test "creates a bucket with full tokens" do
      Bucket.init_bucket({"model-a", :rpm}, 60)
      assert {:ok, %{tokens: 60, capacity: 60}} = Bucket.info({"model-a", :rpm})
    end

    test "overwrites existing bucket" do
      Bucket.init_bucket({"model-a", :rpm}, 60)
      Bucket.init_bucket({"model-a", :rpm}, 120)
      assert {:ok, %{tokens: 120, capacity: 120}} = Bucket.info({"model-a", :rpm})
    end
  end

  describe "take/3" do
    test "returns :ok when tokens available" do
      Bucket.init_bucket({"model-a", :rpm}, 10)
      assert :ok = Bucket.take({"model-a", :rpm}, 1)
    end

    test "decrements tokens on take" do
      Bucket.init_bucket({"model-a", :rpm}, 10)
      :ok = Bucket.take({"model-a", :rpm}, 3)
      {:ok, %{tokens: tokens}} = Bucket.info({"model-a", :rpm})
      assert tokens == 7
    end

    test "returns {:wait, ms} when insufficient tokens" do
      Bucket.init_bucket({"model-a", :rpm}, 2)
      :ok = Bucket.take({"model-a", :rpm}, 2)
      assert {:wait, ms} = Bucket.take({"model-a", :rpm}, 1)
      assert ms > 0
    end

    test "returns :ok for non-existent bucket (unlimited)" do
      assert :ok = Bucket.take({"nonexistent", :rpm}, 100)
    end

    test "multiple takes drain the bucket" do
      Bucket.init_bucket({"model-a", :rpm}, 5)

      for _ <- 1..5 do
        assert :ok = Bucket.take({"model-a", :rpm}, 1)
      end

      assert {:wait, _} = Bucket.take({"model-a", :rpm}, 1)
    end

    test "take exact amount empties bucket" do
      Bucket.init_bucket({"exact", :rpm}, 3)
      assert :ok = Bucket.take({"exact", :rpm}, 3)
      {:ok, %{tokens: 0}} = Bucket.info({"exact", :rpm})
      assert {:wait, _} = Bucket.take({"exact", :rpm}, 1)
    end
  end

  describe "refill/3" do
    test "adds tokens proportional to elapsed time" do
      clock_start = fn -> 0 end
      Bucket.init_bucket({"model-a", :rpm}, 60, clock_start)
      for _ <- 1..60, do: Bucket.take({"model-a", :rpm}, 1, clock_start)
      {:ok, %{tokens: 0}} = Bucket.info({"model-a", :rpm})

      clock_30s = fn -> 30_000 end
      new_tokens = Bucket.refill({"model-a", :rpm}, 1.0, clock_30s)
      assert new_tokens == 30
    end

    test "does not exceed capacity" do
      clock_fn = fn -> 0 end
      Bucket.init_bucket({"model-a", :rpm}, 10, clock_fn)
      clock_100s = fn -> 100_000 end
      new_tokens = Bucket.refill({"model-a", :rpm}, 1.0, clock_100s)
      assert new_tokens == 10
    end

    test "no-op for non-existent bucket" do
      assert 0 = Bucket.refill({"nonexistent", :rpm}, 1.0)
    end
  end

  describe "set_capacity/2" do
    test "updates capacity and clamps tokens" do
      Bucket.init_bucket({"model-a", :rpm}, 100)
      Bucket.set_capacity({"model-a", :rpm}, 10)
      {:ok, %{tokens: 10, capacity: 10}} = Bucket.info({"model-a", :rpm})
    end

    test "preserves tokens when new capacity is larger" do
      Bucket.init_bucket({"model-a", :rpm}, 10)
      :ok = Bucket.take({"model-a", :rpm}, 5)
      Bucket.set_capacity({"model-a", :rpm}, 200)
      {:ok, info} = Bucket.info({"model-a", :rpm})
      assert info.tokens == 5
      assert info.capacity == 200
    end
  end

  describe "delete/1" do
    test "removes the bucket" do
      Bucket.init_bucket({"model-a", :rpm}, 60)
      Bucket.delete({"model-a", :rpm})
      assert :not_found = Bucket.info({"model-a", :rpm})
    end
  end

  describe "info/1" do
    test "returns :not_found for missing bucket" do
      assert :not_found = Bucket.info({"missing", :rpm})
    end
  end
end
