# async: false — two tests below mutate the __BURRITO env var, which is a
# process/node-global side effect incompatible with async test execution.
# The remaining tests use `Application.put_env(:code_puppy_control,
# :user_data_dir_override, tmp)` (see ) to redirect the :user_data
# basedir to a per-test tmp dir instead of writing to the CI runner's
# real user-data home. `Application.put_env` is itself global application
# state, so this file must stay `async: false` even if the __BURRITO
# tests are later extracted — a future refactor would need
# per-process/per-test state (e.g. a registry or ETS keyed by self()) to
# justify flipping async: true.
defmodule CodePuppyControl.ReleaseConfigTest do
  use ExUnit.Case, async: false

  alias CodePuppyControl.Config

  # ── Setup ────────────────────────────────────────────────────────────────
  # Every test gets a fresh temp dir installed as the user_data_dir override,
  # so calls to Config.default_secret_key_base/0 and
  # Config.default_database_path/0 write inside the tmp dir — not into the
  # CI runner's real ~/Library/Application Support/code_puppy/ (macOS) or
  # ~/.local/share/code_puppy/ (Linux).

  setup do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "release_config_test_#{:erlang.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp_dir)

    previous_override =
      Application.get_env(:code_puppy_control, :user_data_dir_override)

    Application.put_env(:code_puppy_control, :user_data_dir_override, tmp_dir)

    on_exit(fn ->
      case previous_override do
        nil -> Application.delete_env(:code_puppy_control, :user_data_dir_override)
        prev -> Application.put_env(:code_puppy_control, :user_data_dir_override, prev)
      end

      File.rm_rf(tmp_dir)
    end)

    {:ok, tmp_dir: tmp_dir}
  end

  # ── Releases config (pure, no side effects) ─────────────────────────────

  describe "releases config" do
    test "releases/0 is configured in mix.exs" do
      releases = Mix.Project.config()[:releases]
      assert is_list(releases)
      assert Keyword.has_key?(releases, :code_puppy_control)
    end

    test ":assemble step is present" do
      opts = Mix.Project.config()[:releases][:code_puppy_control]
      assert :assemble in opts[:steps]
    end

    test "burrito wrap step is the actual Burrito.wrap/1 function" do
      opts = Mix.Project.config()[:releases][:code_puppy_control]
      steps = opts[:steps]
      wrap_fn = Enum.find(steps, &is_function/1)
      assert wrap_fn, "no function step found (expected &Burrito.wrap/1)"
      info = :erlang.fun_info(wrap_fn)
      assert info[:module] == Burrito
      assert info[:name] == :wrap
      assert info[:arity] == 1
    end

    test "includes all five target platforms" do
      opts = Mix.Project.config()[:releases][:code_puppy_control]
      targets = opts[:burrito][:targets]

      expected = [
        :macos_arm64,
        :macos_x86_64,
        :linux_x86_64,
        :linux_arm64,
        :windows_x86_64
      ]

      for t <- expected do
        assert Keyword.has_key?(targets, t), "missing target: #{t}"
      end
    end

    test "targets have correct OS + CPU tuples" do
      opts = Mix.Project.config()[:releases][:code_puppy_control]
      targets = opts[:burrito][:targets]

      assert targets[:macos_arm64][:os] == :darwin
      assert targets[:macos_arm64][:cpu] == :aarch64
      assert targets[:windows_x86_64][:os] == :windows
      assert targets[:linux_arm64][:cpu] == :aarch64
    end

    test "include_erts is true (self-contained)" do
      opts = Mix.Project.config()[:releases][:code_puppy_control]
      assert opts[:include_erts] == true
    end
  end

  # ── Burrito defaults (ADR-003 isolation) ────────────────────────────────

  describe "Burrito defaults (ADR-003 isolation)" do
    test "default_database_path/0 writes under the user_data override, NOT ~/.code_puppy",
         %{tmp_dir: tmp_dir} do
      path = Config.default_database_path()

      refute String.contains?(path, "/.code_puppy/"),
             "default_database_path must not leak into Python legacy home ~/.code_puppy/"

      assert String.starts_with?(path, tmp_dir),
             "default_database_path must resolve under the user_data_dir_override (got: #{path})"

      assert String.ends_with?(path, "data.sqlite")
    end

    test "default_secret_key_base/0 returns a key of at least 64 bytes" do
      key = Config.default_secret_key_base()
      assert is_binary(key)
      assert byte_size(key) >= 64
    end

    test "default_secret_key_base/0 is stable across calls (persisted)" do
      k1 = Config.default_secret_key_base()
      k2 = Config.default_secret_key_base()
      assert k1 == k2, "secret key base must persist; got fresh key on second call"
    end

    test "default_secret_key_base/0 persists under the user_data override",
         %{tmp_dir: tmp_dir} do
      _ = Config.default_secret_key_base()
      key_file = Path.join(tmp_dir, "secret_key_base")

      assert File.exists?(key_file),
             "secret_key_base must be persisted under user_data_dir_override"
    end

    test "burrito_binary?/0 returns false when __BURRITO env var is absent" do
      original = System.get_env("__BURRITO")
      System.delete_env("__BURRITO")

      on_exit(fn ->
        if original, do: System.put_env("__BURRITO", original)
      end)

      refute Config.burrito_binary?()
    end

    test "burrito_binary?/0 returns true when __BURRITO env var is set" do
      original = System.get_env("__BURRITO")
      System.put_env("__BURRITO", "1")

      on_exit(fn ->
        if original,
          do: System.put_env("__BURRITO", original),
          else: System.delete_env("__BURRITO")
      end)

      assert Config.burrito_binary?()
    end
  end

  # ── Burrito CLI dispatch (source-level guards) ──────────────────────────

  describe "Burrito CLI dispatch" do
    test "application.ex has burrito mode detection" do
      # Source-level check: Application must reference __BURRITO so CLI
      # dispatch works when running as a Burrito binary. This is fragile
      # but appropriate — we can't easily test Application.start/2 without
      # actually starting the supervision tree.
      source = File.read!("lib/code_puppy_control/application.ex")

      assert source =~ "__BURRITO",
             "Application must detect __BURRITO env var to dispatch CLI from Burrito binary"
    end

    test "application.ex reads argv via :init.get_plain_arguments (not Burrito runtime)" do
      source = File.read!("lib/code_puppy_control/application.ex")

      assert source =~ ":init.get_plain_arguments",
             "Application must read Burrito argv via :init.get_plain_arguments/0, " <>
               "not Burrito.Util.Args (runtime: false dep)"
    end
  end
end
