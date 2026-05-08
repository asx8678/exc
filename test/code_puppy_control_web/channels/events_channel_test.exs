defmodule CodePuppyControlWeb.EventsChannelTest do
  use CodePuppyControlWeb.ChannelCase, async: false

  describe "join" do
    test "joins events channel successfully for a session" do
      socket = connect_socket("my-session")
      {:ok, reply, _socket} = Phoenix.ChannelTest.join(socket, "events:my-session", %{})

      assert reply.session_id == "my-session"
      assert reply.status == "joined"
    end

    test "joins with replay disabled" do
      socket = connect_socket("no-replay")

      {:ok, _reply, _socket} =
        Phoenix.ChannelTest.join(socket, "events:no-replay", %{"replay" => false})
    end

    test "rejects unauthorized session (token doesn't match)" do
      # Connect with token for "session-a" but try to join "session-b"
      socket = connect_socket("session-a")

      {:error, %{reason: "unauthorized"}} =
        Phoenix.ChannelTest.join(socket, "events:session-b", %{})
    end
  end

  describe "ping" do
    test "replies with pong and timestamps" do
      socket = connect_socket("ping-session")

      {:ok, _reply, socket} =
        Phoenix.ChannelTest.join(socket, "events:ping-session", %{"replay" => false})

      ref = Phoenix.ChannelTest.push(socket, "ping", %{"client_time" => "2026-01-01T00:00:00Z"})
      assert_reply ref, :ok, %{"pong" => _, "client_time" => "2026-01-01T00:00:00Z"}
    end
  end

  describe "replay" do
    test "requests replay and receives replay push" do
      socket = connect_socket("replay-session")

      {:ok, _reply, socket} =
        Phoenix.ChannelTest.join(socket, "events:replay-session", %{"replay" => false})

      Phoenix.ChannelTest.push(socket, "replay", %{"since" => 0, "limit" => 50})

      # The channel sends replay as a push (not a reply) since handle_in returns {:noreply, socket}
      assert_push "replay", payload, 500
      assert is_list(payload.events)
      assert is_integer(payload.count)
    end
  end

  describe "event broadcasting" do
    test "receives events broadcast via EventBus" do
      socket = connect_socket("broadcast-session")

      {:ok, _reply, _socket} =
        Phoenix.ChannelTest.join(socket, "events:broadcast-session", %{"replay" => false})

      # Broadcast a test event to the session topic
      CodePuppyControl.EventBus.broadcast_text("run-1", "broadcast-session", "Hello from test")

      # The channel should receive the event via PubSub and push it to the client
      assert_push "event", payload, 500
      assert payload.type == "text"
      assert payload.content == "Hello from test"
    end
  end

  describe "terminate" do
    test "unsubscribes from EventBus on channel leave" do
      socket = connect_socket("leave-session")

      {:ok, _reply, socket} =
        Phoenix.ChannelTest.join(socket, "events:leave-session", %{"replay" => false})

      # Leave the channel — no crash is the main assertion
      Phoenix.ChannelTest.leave(socket)
    end
  end
end
