defmodule CodePuppyControl.Agent.CompatTest do
  use ExUnit.Case, async: true

  alias CodePuppyControl.Agent.{RunContext, RunUsage, UsageLimits}
  alias CodePuppyControl.Tool.Response

  # ═══════════════════════════════════════════════════════════════════════
  # RunUsage
  # ═══════════════════════════════════════════════════════════════════════

  describe "RunUsage" do
    test "new/0 returns zeroed struct" do
      usage = RunUsage.new()
      assert usage.requests == 0
      assert usage.tool_calls == 0
      assert usage.input_tokens == 0
      assert usage.output_tokens == 0
      assert usage.cache_write_tokens == 0
      assert usage.cache_read_tokens == 0
      assert usage.details == %{}
    end

    test "new/1 from keyword list" do
      usage = RunUsage.new(requests: 3, input_tokens: 500, output_tokens: 200)
      assert usage.requests == 3
      assert usage.input_tokens == 500
      assert usage.output_tokens == 200
      assert usage.tool_calls == 0
    end

    test "new/1 from map" do
      usage = RunUsage.new(%{requests: 1, tool_calls: 5})
      assert usage.requests == 1
      assert usage.tool_calls == 5
    end

    test "merge/2 sums all counters" do
      base = RunUsage.new(requests: 2, tool_calls: 1, input_tokens: 1000, output_tokens: 500)
      delta = RunUsage.new(requests: 1, tool_calls: 3, input_tokens: 500, output_tokens: 200)
      merged = RunUsage.merge(base, delta)
      assert merged.requests == 3
      assert merged.tool_calls == 4
      assert merged.input_tokens == 1500
      assert merged.output_tokens == 700
    end

    test "merge/2 with plain map" do
      base = RunUsage.new(requests: 1)
      merged = RunUsage.merge(base, %{requests: 2, input_tokens: 100})
      assert merged.requests == 3
      assert merged.input_tokens == 100
    end

    test "merge/2 sums details maps" do
      base = RunUsage.new(details: %{"reasoning_tokens" => 50})
      delta = RunUsage.new(details: %{"reasoning_tokens" => 30, "other" => 10})
      merged = RunUsage.merge(base, delta)
      assert merged.details == %{"reasoning_tokens" => 80, "other" => 10}
    end

    test "merge/2 preserves cache tokens" do
      base = RunUsage.new(cache_write_tokens: 100, cache_read_tokens: 200)
      delta = RunUsage.new(cache_write_tokens: 50, cache_read_tokens: 75)
      merged = RunUsage.merge(base, delta)
      assert merged.cache_write_tokens == 150
      assert merged.cache_read_tokens == 275
    end

    test "total_tokens/1 computes input + output" do
      usage = RunUsage.new(input_tokens: 1000, output_tokens: 500)
      assert RunUsage.total_tokens(usage) == 1500
    end

    test "to_map/1 serializes correctly" do
      usage = RunUsage.new(requests: 2, input_tokens: 100, output_tokens: 50)
      map = RunUsage.to_map(usage)
      assert map["requests"] == 2
      assert map["input_tokens"] == 100
      assert map["total_tokens"] == 150
    end

    test "empty?/1 detects zero usage" do
      assert RunUsage.empty?(RunUsage.new()) == true
      assert RunUsage.empty?(RunUsage.new(requests: 1)) == false
    end
  end

  # ═══════════════════════════════════════════════════════════════════════
  # RunContext
  # ═══════════════════════════════════════════════════════════════════════

  describe "RunContext" do
    test "new/1 from keyword list" do
      ctx = RunContext.new(run_id: "run-1", model: "claude-sonnet-4-20250514")
      assert ctx.run_id == "run-1"
      assert ctx.model == "claude-sonnet-4-20250514"
      assert ctx.retry == 0
      assert ctx.deps == nil
    end

    test "new/1 from map" do
      ctx = RunContext.new(%{run_id: "r1", agent_session_id: "s1"})
      assert ctx.run_id == "r1"
      assert ctx.agent_session_id == "s1"
    end

    test "default usage is empty RunUsage" do
      ctx = RunContext.new()
      assert ctx.usage == %RunUsage{}
      assert RunUsage.empty?(ctx.usage)
    end

    test "last_attempt?/1 returns true when retry >= max_retries" do
      assert RunContext.last_attempt?(%RunContext{retry: 2, max_retries: 2}) == true
      assert RunContext.last_attempt?(%RunContext{retry: 0, max_retries: 0}) == true
    end

    test "last_attempt?/1 returns false when retry < max_retries" do
      assert RunContext.last_attempt?(%RunContext{retry: 0, max_retries: 2}) == false
    end

    test "with_metadata/2 merges metadata" do
      ctx = %RunContext{metadata: %{foo: 1}}
      updated = RunContext.with_metadata(ctx, %{bar: 2})
      assert updated.metadata == %{foo: 1, bar: 2}
    end

    test "increment_retry/2 increments per-tool counter" do
      ctx = %RunContext{retries: %{}}
      ctx = RunContext.increment_retry(ctx, "read_file")
      assert ctx.retries == %{"read_file" => 1}
      assert ctx.retry == 1
      assert ctx.tool_name == "read_file"

      ctx = RunContext.increment_retry(ctx, "write_file")
      assert ctx.retries == %{"read_file" => 1, "write_file" => 1}
      assert ctx.tool_name == "write_file"
    end

    test "next_step/1 increments run_step" do
      ctx = %RunContext{run_step: 0}
      assert RunContext.next_step(ctx).run_step == 1
    end

    test "to_map/1 converts to plain map" do
      ctx = RunContext.new(run_id: "r1")
      map = RunContext.to_map(ctx)
      assert is_map(map)
      assert map[:run_id] == "r1"
      refute Map.has_key?(map, :__struct__)
    end

    test "implements Access for backward compatibility" do
      ctx = RunContext.new(run_id: "r1", model: "gpt-4o")
      assert ctx[:run_id] == "r1"
      assert ctx[:model] == "gpt-4o"
      assert Access.fetch(ctx, :run_id) == {:ok, "r1"}
    end

    test "deps field carries arbitrary dependency data" do
      deps = %{api_client: MyAPIClient, config: %{timeout: 30}}
      ctx = RunContext.new(deps: deps)
      assert ctx.deps == deps
    end
  end

  # ═══════════════════════════════════════════════════════════════════════
  # UsageLimits
  # ═══════════════════════════════════════════════════════════════════════

  describe "UsageLimits" do
    test "new/1 defaults all limits to nil" do
      limits = UsageLimits.new()
      assert limits.request_limit == nil
      assert limits.tool_calls_limit == nil
      assert limits.input_tokens_limit == nil
      assert limits.cost_limit == nil
    end

    test "new/1 sets specified limits" do
      limits = UsageLimits.new(request_limit: 50, cost_limit: 1000)
      assert limits.request_limit == 50
      assert limits.cost_limit == 1000
    end

    test "check_before_request/2 allows when under limits" do
      limits = UsageLimits.new(request_limit: 10, tool_calls_limit: 5)
      usage = RunUsage.new(requests: 3, tool_calls: 2)
      assert UsageLimits.check_before_request(limits, usage) == {:ok, :checked}
    end

    test "check_before_request/2 blocks when request limit reached" do
      limits = UsageLimits.new(request_limit: 5)
      usage = RunUsage.new(requests: 5)

      assert UsageLimits.check_before_request(limits, usage) ==
               {:error, :limit_exceeded, :request_limit}
    end

    test "check_before_request/2 skips nil limits" do
      limits = UsageLimits.new(request_limit: nil)
      usage = RunUsage.new(requests: 999_999)
      assert UsageLimits.check_before_request(limits, usage) == {:ok, :checked}
    end

    test "check_tokens/2 allows when under all limits" do
      limits = UsageLimits.new(input_tokens_limit: 1000, output_tokens_limit: 500)
      usage = RunUsage.new(input_tokens: 500, output_tokens: 200)
      assert UsageLimits.check_tokens(limits, usage) == {:ok, :checked}
    end

    test "check_tokens/2 blocks when input tokens exceeded" do
      limits = UsageLimits.new(input_tokens_limit: 1000)
      usage = RunUsage.new(input_tokens: 1000)

      assert UsageLimits.check_tokens(limits, usage) ==
               {:error, :limit_exceeded, :input_tokens_limit}
    end

    test "check_tokens/2 blocks when total tokens exceeded" do
      limits = UsageLimits.new(total_tokens_limit: 1000)
      usage = RunUsage.new(input_tokens: 600, output_tokens: 400)

      assert UsageLimits.check_tokens(limits, usage) ==
               {:error, :limit_exceeded, :total_tokens_limit}
    end

    test "check_cost/2 allows when under limit" do
      limits = UsageLimits.new(cost_limit: 500)
      assert UsageLimits.check_cost(limits, 300) == {:ok, :checked}
    end

    test "check_cost/2 blocks when over limit" do
      limits = UsageLimits.new(cost_limit: 500)
      assert UsageLimits.check_cost(limits, 501) == {:error, :limit_exceeded, :cost_limit}
    end

    test "has_token_limits?/1 detects token limits" do
      assert UsageLimits.has_token_limits?(%UsageLimits{}) == false
      assert UsageLimits.has_token_limits?(%UsageLimits{input_tokens_limit: 1000}) == true
      assert UsageLimits.has_token_limits?(%UsageLimits{total_tokens_limit: 5000}) == true
    end

    test "to_map/1 returns plain map" do
      limits = UsageLimits.new(request_limit: 50)
      map = UsageLimits.to_map(limits)
      assert map.request_limit == 50
      refute Map.has_key?(map, :__struct__)
    end
  end

  # ═══════════════════════════════════════════════════════════════════════
  # Tool.Response
  # ═══════════════════════════════════════════════════════════════════════

  describe "Tool.Response" do
    test "text/1 creates text-only response" do
      resp = Response.text("File created")
      assert resp.content == "File created"
      assert resp.binary_content == nil
      assert resp.metadata == %{}
    end

    test "binary/2 creates binary response" do
      data = <<137, 80, 78, 71>>
      resp = Response.binary(data, "image/png")
      assert resp.binary_content == data
      assert resp.media_type == "image/png"
    end

    test "binary/3 with content label" do
      resp = Response.binary(<<1, 2, 3>>, "image/png", "Screenshot attached")
      assert resp.content == "Screenshot attached"
      assert resp.binary_content == <<1, 2, 3>>
    end

    test "with_metadata/2 creates response with metadata" do
      resp = Response.with_metadata("Done", %{file_path: "/tmp/test.ex"})
      assert resp.content == "Done"
      assert resp.metadata == %{file_path: "/tmp/test.ex"}
    end

    test "base64/1 encodes binary content" do
      resp = Response.binary(<<1, 2, 3>>, "application/octet-stream")
      assert Response.base64(resp) == "AQID"
    end

    test "base64/1 returns nil for text-only response" do
      assert Response.base64(Response.text("hello")) == nil
    end

    test "binary?/1 detects binary content" do
      assert Response.binary?(Response.binary(<<1>>, "image/png")) == true
      assert Response.binary?(Response.text("hello")) == false
    end

    test "to_map/1 serializes with base64 binary" do
      resp = Response.binary(<<255>>, "image/png", "Screenshot")
      map = Response.to_map(resp)
      assert map["content"] == "Screenshot"
      assert map["binary_content"] == "/w=="
      assert map["media_type"] == "image/png"
    end

    test "merge_metadata/2 merges metadata" do
      resp = Response.with_metadata("ok", %{a: 1})
      resp = Response.merge_metadata(resp, %{b: 2})
      assert resp.metadata == %{a: 1, b: 2}
    end
  end

  # ═══════════════════════════════════════════════════════════════════════
  # Integration
  # ═══════════════════════════════════════════════════════════════════════

  describe "integration: agent loop limit checking" do
    test "full lifecycle: build context, merge usage, check limits" do
      ctx = RunContext.new(run_id: "run-1", model: "claude-sonnet-4-20250514")
      limits = UsageLimits.new(request_limit: 5, total_tokens_limit: 10_000)

      usage_1 = RunUsage.new(requests: 1, input_tokens: 2000, output_tokens: 500)
      ctx = %{ctx | usage: RunUsage.merge(ctx.usage, usage_1)}
      assert UsageLimits.check_before_request(limits, ctx.usage) == {:ok, :checked}

      usage_2 = RunUsage.new(requests: 1, input_tokens: 3000, output_tokens: 800)
      ctx = %{ctx | usage: RunUsage.merge(ctx.usage, usage_2)}
      assert RunUsage.total_tokens(ctx.usage) == 6300

      usage_3 = RunUsage.new(requests: 3)
      ctx = %{ctx | usage: RunUsage.merge(ctx.usage, usage_3)}

      assert UsageLimits.check_before_request(limits, ctx.usage) ==
               {:error, :limit_exceeded, :request_limit}
    end

    test "retry tracking across tool calls" do
      ctx = RunContext.new(run_id: "r1", max_retries: 2)
      refute RunContext.last_attempt?(ctx)

      ctx = RunContext.increment_retry(ctx, "read_file")
      refute RunContext.last_attempt?(ctx)

      ctx = RunContext.increment_retry(ctx, "read_file")
      assert RunContext.last_attempt?(ctx)

      ctx = RunContext.increment_retry(ctx, "write_file")
      assert ctx.retries == %{"read_file" => 2, "write_file" => 1}
      refute RunContext.last_attempt?(ctx)

      ctx = RunContext.increment_retry(ctx, "write_file")
      assert RunContext.last_attempt?(ctx)
    end

    test "tool returning Response with binary content" do
      png_data = <<137, 80, 78, 71, 13, 10, 26, 10>>
      resp = Response.binary(png_data, "image/png", "Screenshot of the browser page")
      assert Response.binary?(resp)
      assert is_binary(Response.base64(resp))

      map = Response.to_map(resp)
      assert map["content"] == "Screenshot of the browser page"
      assert is_binary(map["binary_content"])
    end
  end
end
