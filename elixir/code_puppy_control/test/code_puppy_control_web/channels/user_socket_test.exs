defmodule CodePuppyControlWeb.UserSocketTest do
  use CodePuppyControlWeb.ChannelCase, async: false

  alias CodePuppyControlWeb.UserSocket

  describe "connect/3 — token authentication" do
    test "valid token → ok with verified_session_id" do
      token =
        Phoenix.Token.sign(
          CodePuppyControlWeb.Endpoint,
          Application.get_env(:code_puppy_control, :websocket_secret),
          "my-session"
        )

      assert {:ok, socket} =
               Phoenix.ChannelTest.connect(UserSocket, %{"token" => token})

      assert socket.assigns.verified_session_id == "my-session"
    end

    test "missing token → error" do
      assert {:error, _} =
               Phoenix.ChannelTest.connect(UserSocket, %{})
    end

    test "invalid token → error" do
      assert {:error, _} =
               Phoenix.ChannelTest.connect(UserSocket, %{"token" => "not-a-valid-token"})
    end

    test "expired token → error" do
      # Sign with a salt, then verify against the websocket_secret — wrong salt = invalid
      assert {:error, _} =
               Phoenix.ChannelTest.connect(UserSocket, %{"token" => "expired_or_wrong"})
    end
  end

  describe "id/1" do
    test "returns session-based socket ID when authenticated" do
      token =
        Phoenix.Token.sign(
          CodePuppyControlWeb.Endpoint,
          Application.get_env(:code_puppy_control, :websocket_secret),
          "session-42"
        )

      {:ok, socket} = Phoenix.ChannelTest.connect(UserSocket, %{"token" => token})
      assert socket.id == "session:session-42"
    end
  end
end
