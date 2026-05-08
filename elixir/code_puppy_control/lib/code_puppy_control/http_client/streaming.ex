defmodule CodePuppyControl.HttpClient.Streaming do
  @moduledoc """
  Streaming internals for `CodePuppyControl.HttpClient`.

  This module owns the low-level stream-process management used by
  `HttpClient.stream/3` — spawning a dedicated process that runs
  `Finch.stream`, forwarding chunks via message passing, and
  implementing the `Stream.resource` callback tuple.

  ## Contract

  Elements yielded by the stream follow this shape:

  - `{:data, chunk}` — Data chunk received from the server (2xx only)
  - `{:done, %{status: status, headers: headers}}` — Stream completed (2xx only)
  - `{:error, reason}` — Transport error or non-2xx status

  You should not call functions in this module directly; use
  `HttpClient.stream/3` instead.
  """

  alias CodePuppyControl.HttpClient
  alias CodePuppyControl.HttpClient.Config

  # ── Public entry point ────────────────────────────────────────────────────

  @doc false
  @spec build_stream(
          HttpClient.method(),
          String.t(),
          [{String.t(), String.t()}],
          String.t() | nil,
          non_neg_integer(),
          non_neg_integer()
        ) :: Enumerable.t()
  def build_stream(method, url, headers, body, pool_timeout, timeout) do
    Stream.resource(
      fn -> start_stream(method, url, headers, body, pool_timeout, timeout) end,
      &next_stream_element/1,
      &close_stream/1
    )
  end

  # ── Stream internals ──────────────────────────────────────────────────────

  # Spawns a process that runs Finch.stream and sends chunks to the caller.
  # This avoids the broken pattern of returning Stream-resource tuples from
  # inside the Finch callback — Finch callbacks must return {:cont, acc}.
  defp start_stream(method, url, headers, body, pool_timeout, timeout) do
    parent = self()
    ref = make_ref()

    pid =
      spawn(fn ->
        run_finch_stream(parent, ref, method, url, headers, body, pool_timeout, timeout)
      end)

    mon_ref = Process.monitor(pid)
    {pid, mon_ref, ref, timeout}
  end

  # Runs Finch.stream in a separate process, sending data chunks to the parent
  # via message passing. For 2xx responses, chunks are sent immediately.
  # For non-2xx, the body is accumulated and sent as a single error element.
  defp run_finch_stream(parent, ref, method, url, headers, body, pool_timeout, timeout) do
    pool_name = Config.default_pool_name()
    req = HttpClient.build_request(method, url, headers, body)

    initial_acc = %{status: nil, headers: [], body_parts: []}

    # Finch.stream/5 wraps the callback return in {:cont, result} before
    # delegating to stream_while/5, so the callback must return the plain
    # accumulator — NOT {:cont, acc}.  Returning {:cont, acc} would nest
    # the accumulator into {:cont, {:cont, map}} on every chunk.
    result =
      Finch.stream(
        req,
        pool_name,
        initial_acc,
        fn
          {:status, status}, acc ->
            %{acc | status: status}

          {:headers, resp_headers}, acc ->
            %{acc | headers: resp_headers}

          {:data, data}, acc ->
            if acc.status in 200..299 do
              send(parent, {ref, {:data, data}})
              acc
            else
              # Non-2xx: accumulate body instead of streaming to parent
              %{acc | body_parts: [data | acc.body_parts]}
            end
        end,
        pool_timeout: pool_timeout,
        receive_timeout: timeout
      )

    case result do
      {:ok, %{status: status, headers: resp_headers}} when status in 200..299 ->
        send(parent, {ref, {:done, %{status: status, headers: resp_headers}}})

      {:ok, %{status: status, headers: resp_headers, body_parts: body_parts}} ->
        body = body_parts |> Enum.reverse() |> Enum.join()
        send(parent, {ref, {:error, %{status: status, headers: resp_headers, body: body}}})

      {:error, reason} ->
        send(parent, {ref, {:transport_error, reason}})
    end
  rescue
    e ->
      send(parent, {ref, {:transport_error, Exception.message(e)}})
  end

  # Receives the next element from the spawned stream process.
  defp next_stream_element({pid, mon_ref, ref, timeout} = state) do
    receive do
      {^ref, {:data, chunk}} ->
        {[{:data, chunk}], state}

      {^ref, {:done, metadata}} ->
        Process.demonitor(mon_ref, [:flush])
        {[{:done, metadata}], :done}

      {^ref, {:error, details}} ->
        Process.demonitor(mon_ref, [:flush])
        {[{:error, details}], :done}

      {^ref, {:transport_error, reason}} ->
        Process.demonitor(mon_ref, [:flush])
        {[{:error, HttpClient.format_error(reason)}], :done}

      {:DOWN, ^mon_ref, :process, ^pid, :normal} ->
        # Process exited normally; drain any final message
        drain_stream_completion(ref)

      {:DOWN, ^mon_ref, :process, ^pid, reason} ->
        {[{:error, "Stream process exited: #{inspect(reason)}"}], :done}
    after
      timeout ->
        Process.exit(pid, :kill)
        Process.demonitor(mon_ref, [:flush])
        {[{:error, "Stream receive timeout"}], :done}
    end
  end

  defp next_stream_element(:done), do: {:halt, :done}

  # After the stream process exits normally, give it a brief window to
  # deliver the final :done / :error / :transport_error message.
  defp drain_stream_completion(ref) do
    receive do
      {^ref, {:done, metadata}} ->
        {[{:done, metadata}], :done}

      {^ref, {:error, details}} ->
        {[{:error, details}], :done}

      {^ref, {:transport_error, reason}} ->
        {[{:error, HttpClient.format_error(reason)}], :done}
    after
      100 ->
        {[{:error, "Stream process exited without completion signal"}], :done}
    end
  end

  defp close_stream({pid, mon_ref, _ref, _timeout}) do
    Process.exit(pid, :kill)
    Process.demonitor(mon_ref, [:flush])
    :ok
  end

  defp close_stream(:done), do: :ok
end
