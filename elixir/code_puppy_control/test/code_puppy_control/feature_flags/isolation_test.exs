defmodule CodePuppyControl.FeatureFlags.IsolationTest do
  use ExUnit.Case, async: false

  alias CodePuppyControl.FeatureFlags
  alias CodePuppyControl.Config.Paths

  # async: false because we manipulate shared env vars and temp files,
  # and register named GenServers.

  @tmp_dir Path.join(
             System.tmp_dir!(),
             "feature_flags_iso_test_#{:erlang.unique_integer([:positive])}"
           )

  setup do
    File.mkdir_p!(@tmp_dir)
    System.put_env("PUP_EX_HOME", @tmp_dir)

    flags_path = Path.join(@tmp_dir, "flags.json")
    File.rm(flags_path)

    on_exit(fn ->
      System.delete_env("PUP_EX_HOME")
      File.rm_rf!(@tmp_dir)
    end)

    %{flags_path: flags_path}
  end

  # ── Isolation guard regression tests (ADR-003) ────────────────────────

  describe "isolation guard: persistence refuses legacy home" do
    test "set returns error and does not create flags.json under legacy home" do
      legacy_home = Paths.legacy_home_dir()
      System.put_env("PUP_EX_HOME", legacy_home)

      legacy_flags_path = Path.join(legacy_home, "flags.json")
      _existed_before = File.exists?(legacy_flags_path)

      server = start_fresh_flags_server()
      result = GenServer.call(server, {:set, :llm_client, true})

      assert {:error, msg} = result,
             "Expected set to return error when flags_file is under legacy home, got: #{inspect(result)}"

      assert msg =~ "Isolation violation",
             "Expected error to mention Isolation violation, got: #{inspect(msg)}"

      assert GenServer.call(server, {:enabled?, :llm_client}) == false

      refute File.exists?(legacy_flags_path),
             "flags.json was created under legacy home despite isolation guard!"

      System.put_env("PUP_EX_HOME", @tmp_dir)
    end

    test "reset returns error and does not create flags.json under legacy home" do
      legacy_home = Paths.legacy_home_dir()
      System.put_env("PUP_EX_HOME", legacy_home)

      legacy_flags_path = Path.join(legacy_home, "flags.json")

      server = start_fresh_flags_server()
      result = GenServer.call(server, :reset)

      assert {:error, msg} = result,
             "Expected reset to return error when flags_file is under legacy home, got: #{inspect(result)}"

      assert msg =~ "Isolation violation",
             "Expected error to mention Isolation violation, got: #{inspect(msg)}"

      refute File.exists?(legacy_flags_path),
             "flags.json was created under legacy home during reset!"

      System.put_env("PUP_EX_HOME", @tmp_dir)
    end
  end

  describe "reset: in-memory state preserved on persistence failure" do
    test "reset does not mutate in-memory state when persist_to_disk fails" do
      test_id = :erlang.unique_integer([:positive])
      ro_dir = Path.join(System.tmp_dir!(), "ff_ro_test_#{test_id}")
      File.mkdir_p!(ro_dir)

      flags_path = Path.join(ro_dir, "flags.json")
      json = Jason.encode!(%{"elixir.llm_client" => true}, pretty: true)
      File.write!(flags_path, json <> "\n")

      File.chmod!(flags_path, 0o444)

      System.put_env("PUP_EX_HOME", ro_dir)

      try do
        server = start_fresh_flags_server()

        assert GenServer.call(server, {:enabled?, :llm_client}) == true

        result = GenServer.call(server, :reset)

        if match?({:error, _}, result) do
          assert GenServer.call(server, {:enabled?, :llm_client}) == true,
                 "In-memory state was mutated to false even though reset failed!"
        end
      after
        File.chmod!(flags_path, 0o644)
        System.put_env("PUP_EX_HOME", @tmp_dir)
        File.rm_rf(ro_dir)
      end
    end
  end

  # ── Test helpers ───────────────────────────────────────────────────────

  defp start_fresh_flags_server do
    name = :"feature_flags_iso_test_#{:erlang.unique_integer([:positive])}"
    start_supervised!({FeatureFlags, name: name})
    name
  end
end
