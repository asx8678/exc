defmodule CodePuppyControlWeb.ChannelCase do
  @moduledoc """
  Shared test case for Phoenix Channel tests.

  Sets up the socket and connects through UserSocket, enabling
  `Phoenix.ChannelTest` helpers for join/push/leave assertions.

  ## Token handling

  In the test environment, `websocket_secret` is set to a known value.
  This module generates a valid signed token for the provided session ID
  so that `UserSocket.connect/3` accepts the connection in the test env.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      import Phoenix.ChannelTest

      alias CodePuppyControlWeb.UserSocket

      # The endpoint for channel tests
      @endpoint CodePuppyControlWeb.Endpoint

      import CodePuppyControlWeb.ChannelCase
    end
  end

  setup_all _tags do
    # Replace the real PtyManager with the Stub for all channel tests.
    # The Stub registers under CodePuppyControl.PtyManager so that
    # PtyManager.create_session/2 etc. route here.
    #
    # We must terminate + delete the child from the supervisor so it
    # doesn't auto-restart, then start the Stub under the same name.
    supervisor = CodePuppyControl.Supervisor

    if _pid = Process.whereis(CodePuppyControl.PtyManager) do
      # 1. Terminate the running child (doesn't delete the child spec)
      :ok = Supervisor.terminate_child(supervisor, CodePuppyControl.PtyManager)
      # 2. Delete the child spec so the supervisor won't restart it
      :ok = Supervisor.delete_child(supervisor, CodePuppyControl.PtyManager)
    end

    # Start the Stub under the PtyManager name
    case CodePuppyControl.PtyManager.Stub.start_link([]) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    on_exit(fn ->
      # Stop the Stub
      if pid = Process.whereis(CodePuppyControl.PtyManager) do
        GenServer.stop(pid, :shutdown)
      end

      # Re-add the real PtyManager to the supervisor
      try do
        spec = %{
          id: CodePuppyControl.PtyManager,
          start: {CodePuppyControl.PtyManager, :start_link, [[]]},
          type: :worker
        }

        Supervisor.start_child(supervisor, spec)
      catch
        :exit, _ -> :ok
      end
    end)

    :ok
  end

  setup _tags do
    # (code_puppy-i1n) Channel tests that join terminal channels trigger
    # Store.register_terminal which uses Ecto/Repo.  Check out the
    # sandbox in {:shared, self()} mode so the Store GenServer can
    # access the Repo without DBConnection.OwnershipError.
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(CodePuppyControl.Repo)
    :ok = Ecto.Adapters.SQL.Sandbox.mode(CodePuppyControl.Repo, {:shared, self()})

    # Ensure PubSub is running for channel tests
    case CodePuppyControl.PubSub |> Process.whereis() do
      nil ->
        {:ok, _} =
          Phoenix.PubSub.PG2.start_link(
            name: CodePuppyControl.PubSub,
            adapter_name: CodePuppyControl.PubSub
          )

      _pid ->
        :ok
    end

    # Ensure EventStore is running
    case Process.whereis(CodePuppyControl.EventStore) do
      nil ->
        {:ok, _} = CodePuppyControl.EventStore.start_link([])

      _pid ->
        :ok
    end

    # Clean stub state between tests
    try do
      CodePuppyControl.PtyManager.Stub.clear_all()
    catch
      :exit, _ -> :ok
    end

    :ok
  end

  @doc """
  Connect a socket for testing with a signed token for "test-session".

  Uses the test `websocket_secret` to sign a valid token so that
  `UserSocket.connect/3` accepts the connection in test env.
  """
  @spec connect_socket() :: Phoenix.Socket.t()
  defmacro connect_socket do
    quote do
      token =
        Phoenix.Token.sign(
          CodePuppyControlWeb.Endpoint,
          Application.get_env(:code_puppy_control, :websocket_secret),
          "test-session"
        )

      {:ok, socket} =
        Phoenix.ChannelTest.connect(
          CodePuppyControlWeb.UserSocket,
          %{"token" => token}
        )

      socket
    end
  end

  @doc """
  Connect a socket with a specific session ID in the token.

  The session ID must match the channel topic you intend to join,
  e.g. `connect_socket("my-session")` → join `"events:my-session"`.
  """
  @spec connect_socket(String.t()) :: Phoenix.Socket.t()
  defmacro connect_socket(session_id) do
    quote do
      token =
        Phoenix.Token.sign(
          CodePuppyControlWeb.Endpoint,
          Application.get_env(:code_puppy_control, :websocket_secret),
          unquote(session_id)
        )

      {:ok, socket} =
        Phoenix.ChannelTest.connect(
          CodePuppyControlWeb.UserSocket,
          %{"token" => token}
        )

      socket
    end
  end
end
