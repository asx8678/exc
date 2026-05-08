defmodule CodePuppyControl.Evals.LoggerTest do
  @moduledoc """
  Parity gate for: Elixir `log_eval` output must decode identically
  to the evals reference JSON (modulo the timestamp field, which varies).

  Also covers sanitization, truncation, and directory resolution.
  """
  use ExUnit.Case, async: false

  alias CodePuppyControl.Evals.{Logger, Result, ToolCall}

  @fixture_path Path.expand(
                  "../../fixtures/evals/evals_reference.json",
                  __DIR__
                )

  setup do
    tmp = Path.join([System.tmp_dir!(), "cp_evals_#{System.unique_integer([:positive])}"])
    File.mkdir_p!(tmp)

    prev = Application.get_env(:code_puppy_control, :evals_log_dir)
    Application.put_env(:code_puppy_control, :evals_log_dir, tmp)

    on_exit(fn ->
      File.rm_rf!(tmp)

      if prev do
        Application.put_env(:code_puppy_control, :evals_log_dir, prev)
      else
        Application.delete_env(:code_puppy_control, :evals_log_dir)
      end
    end)

    %{tmp: tmp}
  end

  describe "sanitize_name/1" do
    test "lowercases, replaces spaces and slashes" do
      assert Logger.sanitize_name("My Eval") == "my_eval"
      assert Logger.sanitize_name("foo/bar") == "foo_bar"
      assert Logger.sanitize_name("Multi Word / Name") == "multi_word___name"
    end
  end

  describe "log_eval/2" do
    test "writes JSON to <log_dir>/<sanitized>.json", %{tmp: tmp} do
      result = %Result{
        response_text: "hello",
        model_name: "m",
        duration_seconds: 0.1,
        tool_calls: []
      }

      assert :ok = Logger.log_eval("Smoke Test", result)
      path = Path.join(tmp, "smoke_test.json")
      assert File.exists?(path)

      decoded = path |> File.read!() |> Jason.decode!()
      assert decoded["name"] == "Smoke Test"
      assert decoded["model"] == "m"
      assert decoded["duration_seconds"] == 0.1
      assert decoded["response_text"] == "hello"
      assert decoded["tool_calls"] == []
      assert is_binary(decoded["timestamp"])
    end

    test "truncates response_text at 2000 chars", %{tmp: tmp} do
      long = String.duplicate("a", 2500)
      result = %Result{response_text: long, model_name: "m"}

      :ok = Logger.log_eval("trunc", result)
      decoded = Path.join(tmp, "trunc.json") |> File.read!() |> Jason.decode!()

      assert String.length(decoded["response_text"]) == 2000
    end

    test "serializes tool calls with Python-compatible keys", %{tmp: tmp} do
      tc = ToolCall.new("read_file", %{"path" => "README.md"}, "# ...")

      result = %Result{
        response_text: "ok",
        model_name: "mock-model",
        duration_seconds: 1.5,
        tool_calls: [tc]
      }

      :ok = Logger.log_eval("parity_gate", result)

      [tool_call] =
        Path.join(tmp, "parity_gate.json")
        |> File.read!()
        |> Jason.decode!()
        |> Map.fetch!("tool_calls")

      assert tool_call == %{
               "name" => "read_file",
               "args" => %{"path" => "README.md"},
               "result" => "# ..."
             }
    end
  end

  describe "JSON parity with reference fixture (acceptance gate)" do
    test "Elixir output decodes identically to evals_reference.json modulo timestamp",
         %{tmp: tmp} do
      # Build the Elixir input that mirrors the Python fixture
      result = %Result{
        response_text: "I'll read the file for you.",
        model_name: "mock-model",
        duration_seconds: 1.5,
        tool_calls: [
          ToolCall.new("read_file", %{"path" => "README.md"}, "# Code Puppy...")
        ]
      }

      :ok = Logger.log_eval("parity_gate", result)

      elixir_decoded =
        Path.join(tmp, "parity_gate.json") |> File.read!() |> Jason.decode!()

      # Load reference fixture (its timestamp is the placeholder "__TIMESTAMP__")
      reference_decoded = @fixture_path |> File.read!() |> Jason.decode!()

      # Compare every field except timestamp (which varies per run)
      assert Map.delete(elixir_decoded, "timestamp") ==
               Map.delete(reference_decoded, "timestamp"),
             """
             Elixir log_eval output does NOT match Python reference schema.

             Elixir: #{inspect(Map.delete(elixir_decoded, "timestamp"), pretty: true)}

             Reference: #{inspect(Map.delete(reference_decoded, "timestamp"), pretty: true)}
             """

      # Timestamp must exist and be ISO8601-ish (parses as NaiveDateTime)
      assert {:ok, _dt} = NaiveDateTime.from_iso8601(elixir_decoded["timestamp"])
    end

    test "key-order in raw JSON matches Python reference", %{tmp: tmp} do
      # Python json.dumps emits keys in insertion order:
      # name, timestamp, model, duration_seconds, response_text, tool_calls
      # Our encoder must match because downstream tooling may do string diffs.
      result = %Result{
        response_text: "x",
        model_name: "m",
        duration_seconds: 0.0,
        tool_calls: []
      }

      :ok = Logger.log_eval("keyorder", result)
      raw = Path.join(tmp, "keyorder.json") |> File.read!()

      # Find positions of each key in the raw JSON; they must be monotonically increasing.
      # NOTE: :binary.match/2 returns the FIRST occurrence. This test is safe because
      # tool_calls is [] — if you add tool calls to this test case, the nested "name",
      # "args", and "result" keys INSIDE tool_calls objects would shift the first-match
      # offsets and make this assertion misleading. If you need tool_calls populated
      # here, scope each search with :binary.matches/2 + the outer object slice.
      keys = ~w(name timestamp model duration_seconds response_text tool_calls)
      positions = Enum.map(keys, fn k -> {k, :binary.match(raw, ~s("#{k}"))} end)

      # Fail loudly if any key is missing
      for {k, pos} <- positions do
        refute pos == :nomatch, "key #{k} missing from JSON"
      end

      offsets = Enum.map(positions, fn {_, {off, _}} -> off end)

      assert offsets == Enum.sort(offsets),
             "JSON key order does not match Python (expected: #{inspect(keys)}, got offsets: #{inspect(offsets)})"
    end
  end
end
