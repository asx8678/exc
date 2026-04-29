defmodule CodePuppyControl.FeatureFlags.FlagsTest do
  use ExUnit.Case, async: false

  alias CodePuppyControl.FeatureFlags.Flags
  alias CodePuppyControl.Config.Paths

  # async: false because Paths describe manipulates PUP_EX_HOME.
  # Pure Flags.* tests themselves are side-effect-free.

  describe "Flags.all/0" do
    test "returns list of known capabilities with descriptions" do
      capabilities = Flags.all()

      assert length(capabilities) == 5

      assert Enum.all?(capabilities, fn {name, desc} ->
               is_atom(name) and is_binary(desc)
             end)
    end

    test "includes all ADR-004 capabilities" do
      names = Flags.names()

      for expected <- [:llm_client, :base_agent, :tools, :plugins, :cli] do
        assert expected in names, "Expected #{expected} in capability names"
      end
    end
  end

  describe "Flags.names/0" do
    test "returns atom list" do
      names = Flags.names()

      assert is_list(names)
      assert length(names) == 5
      assert Enum.all?(names, &is_atom/1)
    end
  end

  describe "Flags.known?/1" do
    test "returns true for known capabilities" do
      for name <- Flags.names() do
        assert Flags.known?(name), "Expected known?(#{inspect(name)}) to be true"
      end
    end

    test "returns false for unknown atoms" do
      refute Flags.known?(:nonexistent)
    end

    test "returns false for non-atom input" do
      refute Flags.known?("llm_client")
      refute Flags.known?(123)
    end
  end

  describe "Flags.resolve/1" do
    test "resolves known atoms to themselves" do
      for name <- Flags.names() do
        assert {:ok, ^name} = Flags.resolve(name)
      end
    end

    test "resolves string without prefix" do
      assert {:ok, :llm_client} = Flags.resolve("llm_client")
    end

    test "resolves string with elixir. prefix" do
      assert {:ok, :llm_client} = Flags.resolve("elixir.llm_client")
    end

    test "resolves case-insensitively" do
      assert {:ok, :llm_client} = Flags.resolve("LLM_CLIENT")
      assert {:ok, :llm_client} = Flags.resolve("elixir.LLM_CLIENT")
      assert {:ok, :base_agent} = Flags.resolve("Base_Agent")
    end

    test "resolves strings with whitespace" do
      assert {:ok, :cli} = Flags.resolve("  cli  ")
      assert {:ok, :cli} = Flags.resolve("  elixir.cli  ")
    end

    test "returns error for unknown atoms" do
      assert {:error, :unknown} = Flags.resolve(:nonexistent)
    end

    test "returns error for unknown strings" do
      assert {:error, :unknown} = Flags.resolve("nonexistent")
      assert {:error, :unknown} = Flags.resolve("elixir.nonexistent")
    end
  end

  describe "Flags.json_key/1" do
    test "prefixes capability with elixir." do
      assert Flags.json_key(:llm_client) == "elixir.llm_client"
      assert Flags.json_key(:cli) == "elixir.cli"
    end

    test "round-trips through resolve" do
      for name <- Flags.names() do
        json_key = Flags.json_key(name)
        assert {:ok, ^name} = Flags.resolve(json_key)
      end
    end
  end

  # Paths integration needs env var manipulation — async: false inside its own describe
  describe "Paths.flags_file/0 integration" do
    @tmp_dir Path.join(
               System.tmp_dir!(),
               "feature_flags_flags_test_#{:erlang.unique_integer([:positive])}"
             )

    setup do
      File.mkdir_p!(@tmp_dir)
      System.put_env("PUP_EX_HOME", @tmp_dir)

      on_exit(fn ->
        System.delete_env("PUP_EX_HOME")
        File.rm_rf!(@tmp_dir)
      end)

      :ok
    end

    test "flags_file resolves under PUP_EX_HOME" do
      assert Paths.flags_file() == Path.join(@tmp_dir, "flags.json")
    end
  end
end
