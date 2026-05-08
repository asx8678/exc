defmodule CodePuppyControlWeb.HealthChannelTest do
  use CodePuppyControlWeb.ChannelCase, async: false

  describe "join" do
    test "joins health channel successfully" do
      socket = connect_socket()
      {:ok, reply, _socket} = Phoenix.ChannelTest.join(socket, "health", %{})

      assert reply.status == "connected"
    end
  end

  describe "echo" do
    test "echoes text back with prefix" do
      socket = connect_socket()
      {:ok, _reply, socket} = Phoenix.ChannelTest.join(socket, "health", %{})

      # Flush the initial status push
      assert_push "status", _

      ref = Phoenix.ChannelTest.push(socket, "echo", %{"text" => "hello"})
      assert_reply ref, :ok, %{"text" => "echo: hello"}
    end

    test "echoes any payload as fallback" do
      socket = connect_socket()
      {:ok, _reply, socket} = Phoenix.ChannelTest.join(socket, "health", %{})
      assert_push "status", _

      ref = Phoenix.ChannelTest.push(socket, "echo", %{"unexpected" => "data"})
      assert_reply ref, :ok, %{"text" => text}
      # Should contain "echo:" somewhere
      assert String.contains?(text, "echo:")
    end
  end

  describe "ping" do
    test "replies with pong and timestamps" do
      socket = connect_socket()
      {:ok, _reply, socket} = Phoenix.ChannelTest.join(socket, "health", %{})
      assert_push "status", _

      ref = Phoenix.ChannelTest.push(socket, "ping", %{"client_time" => "2026-01-01T00:00:00Z"})
      assert_reply ref, :ok, %{"pong" => _, "client_time" => "2026-01-01T00:00:00Z"}
    end
  end

  describe "status" do
    test "replies with health status on request" do
      socket = connect_socket()
      {:ok, _reply, socket} = Phoenix.ChannelTest.join(socket, "health", %{})
      assert_push "status", _

      ref = Phoenix.ChannelTest.push(socket, "status", %{})
      assert_reply ref, :ok, status

      assert status.status == "ok"
      assert %{} = status.vm
      assert is_integer(status.vm.process_count)
      assert is_float(status.vm.memory_total_mb)
      assert is_integer(status.vm.scheduler_count)
      assert is_integer(status.vm.scheduler_online)
      assert is_binary(status.vm.otp_version)
    end

    test "receives initial status push on join" do
      socket = connect_socket()
      {:ok, _reply, _socket} = Phoenix.ChannelTest.join(socket, "health", %{})

      # The join triggers an immediate status push
      assert_push "status", status
      assert status.status == "ok"
    end

    test "only one status push per interval (no double-scheduling)" do
      socket = connect_socket()
      {:ok, _reply, _socket} = Phoenix.ChannelTest.join(socket, "health", %{})

      # Flush the initial status push triggered by join
      assert_push "status", _

      # No additional status push should arrive immediately — the next
      # one is scheduled after @health_interval_ms. If join had both
      # send() and schedule_health(), we would see a second push here.
      refute_push "status", _, 50
    end
  end
end
