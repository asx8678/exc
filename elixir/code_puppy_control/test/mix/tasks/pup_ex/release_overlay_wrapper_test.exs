defmodule Mix.Tasks.PupEx.ReleaseOverlayWrapperTest do
  @moduledoc """
  Subprocess regressions for the `mix release` shell overlay wrappers.

  The wrappers live under `rel/overlays/bin/` and are copied into a
  traditional Mix release. They must prefer the Elixir release escript
  and must not silently fall back to the legacy Python CLIs unless an
  operator explicitly opts in with `PUP_ALLOW_LEGACY_PYTHON_CLI=1`.

  Refs: code-puppy-yl5
  """

  use ExUnit.Case, async: true

  @legacy_env "PUP_ALLOW_LEGACY_PYTHON_CLI"
  @wrappers ["pup", "code-puppy", "gac"]

  setup do
    project_root = project_root!()

    tmp_root =
      Path.join(
        System.tmp_dir!(),
        "pup_release_wrapper_#{:erlang.unique_integer([:positive])}_#{System.system_time(:millisecond)}"
      )

    File.mkdir_p!(tmp_root)
    on_exit(fn -> File.rm_rf(tmp_root) end)

    {:ok, project_root: project_root, tmp_root: tmp_root}
  end

  test "legacy Python CLI fallback is disabled unless explicitly allowed", %{
    project_root: project_root,
    tmp_root: tmp_root
  } do
    for wrapper <- @wrappers do
      {wrapper_path, _release_dir} = install_wrapper!(project_root, tmp_root, wrapper)
      marker = Path.join(tmp_root, "legacy_#{wrapper}.marker")
      legacy_dir = install_legacy_cli!(tmp_root, wrapper, marker)

      {output, exit_code} =
        run_wrapper(wrapper_path, ["--sentinel"], [legacy_dir], legacy?: false)

      assert exit_code == 1, "#{wrapper} should fail without implicit legacy fallback: #{output}"
      refute File.exists?(marker), "#{wrapper} executed the legacy CLI without #{@legacy_env}=1"
      assert output =~ "fallback is disabled by default"
      assert output =~ @legacy_env
    end
  end

  test "explicit legacy opt-in delegates after Elixir release executable is unavailable", %{
    project_root: project_root,
    tmp_root: tmp_root
  } do
    for wrapper <- @wrappers do
      {wrapper_path, _release_dir} = install_wrapper!(project_root, tmp_root, wrapper)
      marker = Path.join(tmp_root, "legacy_opt_in_#{wrapper}.marker")
      legacy_dir = install_legacy_cli!(tmp_root, wrapper, marker)

      {output, exit_code} = run_wrapper(wrapper_path, ["--sentinel"], [legacy_dir], legacy?: true)

      assert exit_code == 42, "#{wrapper} should delegate to explicit legacy fallback: #{output}"
      assert File.read!(marker) == "legacy #{wrapper}\n"
    end
  end

  test "Elixir release escript is preferred even when legacy opt-in is set", %{
    project_root: project_root,
    tmp_root: tmp_root
  } do
    for wrapper <- @wrappers do
      {wrapper_path, release_dir} = install_wrapper!(project_root, tmp_root, wrapper)
      escript_path = install_release_escript!(release_dir)

      legacy_marker = Path.join(tmp_root, "legacy_preferred_#{wrapper}.marker")
      legacy_dir = install_legacy_cli!(tmp_root, wrapper, legacy_marker)

      elixir_marker = Path.join(tmp_root, "elixir_#{wrapper}.marker")
      elixir_dir = install_fake_elixir!(tmp_root, elixir_marker)

      {output, exit_code} =
        run_wrapper(wrapper_path, ["--sentinel"], [elixir_dir, legacy_dir], legacy?: true)

      assert exit_code == 43, "#{wrapper} should execute the Elixir release path: #{output}"

      refute File.exists?(legacy_marker),
             "#{wrapper} used legacy fallback despite release escript"

      elixir_args = elixir_marker |> File.read!() |> String.split("\n", trim: true)
      assert elixir_args |> hd() |> Path.expand() == escript_path
      assert "--sentinel" in elixir_args

      if wrapper == "gac" do
        assert "gac" in elixir_args
      end
    end
  end

  defp project_root! do
    # __DIR__ = test/mix/tasks/pup_ex/  →  up 4 = project root
    root = Path.expand(Path.join(__DIR__, "../../../.."))

    unless File.exists?(Path.join(root, "mix.exs")) do
      flunk("could not locate mix.exs from #{__DIR__} (resolved root=#{root})")
    end

    root
  end

  defp install_wrapper!(project_root, tmp_root, wrapper) do
    release_dir = Path.join(tmp_root, "release_#{wrapper}")
    bin_dir = Path.join(release_dir, "bin")
    File.mkdir_p!(bin_dir)

    source = Path.join([project_root, "rel", "overlays", "bin", wrapper])
    destination = Path.join(bin_dir, wrapper)

    File.cp!(source, destination)
    File.chmod!(destination, 0o755)

    {destination, release_dir}
  end

  defp install_release_escript!(release_dir) do
    escript_path =
      Path.join([
        release_dir,
        "lib",
        "code_puppy_control-0.0.0-test",
        "priv",
        "bin",
        "code_puppy_control"
      ])

    File.mkdir_p!(Path.dirname(escript_path))
    File.write!(escript_path, "fake escript\n")

    escript_path
  end

  defp install_legacy_cli!(tmp_root, wrapper, marker) do
    legacy_dir = Path.join(tmp_root, "legacy_#{wrapper}")
    File.mkdir_p!(legacy_dir)

    legacy_path = Path.join(legacy_dir, wrapper)

    File.write!(
      legacy_path,
      """
      #!/bin/sh
      echo #{shell_quote("legacy #{wrapper}")} > #{shell_quote(marker)}
      exit 42
      """
    )

    File.chmod!(legacy_path, 0o755)
    legacy_dir
  end

  defp install_fake_elixir!(tmp_root, marker) do
    elixir_dir = Path.join(tmp_root, "fake_elixir")
    File.mkdir_p!(elixir_dir)

    elixir_path = Path.join(elixir_dir, "elixir")

    File.write!(
      elixir_path,
      """
      #!/bin/sh
      printf '%s\n' "$@" > #{shell_quote(marker)}
      exit 43
      """
    )

    File.chmod!(elixir_path, 0o755)
    elixir_dir
  end

  defp run_wrapper(wrapper_path, args, path_entries, legacy?: legacy?) do
    env = [
      {"PATH", test_path(path_entries)},
      {@legacy_env, if(legacy?, do: "1", else: nil)}
    ]

    System.cmd(wrapper_path, args, env: env, stderr_to_stdout: true)
  end

  defp test_path(entries) do
    case System.get_env("PATH") do
      nil -> Enum.join(entries, ":")
      "" -> Enum.join(entries, ":")
      current -> Enum.join(entries ++ [current], ":")
    end
  end

  defp shell_quote(value) do
    "'" <> String.replace(value, "'", "'\\''") <> "'"
  end
end
