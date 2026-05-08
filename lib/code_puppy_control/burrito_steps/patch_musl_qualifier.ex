defmodule CodePuppyControl.BurritoSteps.PatchMuslQualifier do
  @moduledoc """
  Burrito build step that patches target qualifiers for musl-based Linux targets.

  Burrito's `Target.init_target/2` uses `Keyword.split(definition, [:os, :cpu, :debug?])`
  which prevents the `:os` key from reaching qualifiers. But `Target.make_triplet/1`
  checks `target.qualifiers[:os] == :linux` to append `-musl` to the Zig target triple.

  This step bridges the gap: if a target has `musl: true` in its qualifiers, we inject
  `os: :linux` into qualifiers so that `make_triplet/1` produces the correct
  `x86_64-linux-musl` or `aarch64-linux-musl` triplet for Zig cross-compilation.

  ## Target definition in mix.exs

      linux_musl_x86_64: [os: :linux, cpu: :x86_64, musl: true]
      linux_musl_arm64: [os: :linux, cpu: :aarch64, musl: true]

  See for background.
  """

  alias Burrito.Builder.Context
  alias Burrito.Builder.Target

  @behaviour Burrito.Builder.Step

  @impl true
  def execute(%Context{} = context) do
    %Target{} = target = context.target

    if target.qualifiers[:musl] == true do
      patched_qualifiers = Keyword.put(target.qualifiers, :os, :linux)
      patched_target = %{target | qualifiers: patched_qualifiers}

      %Context{context | target: patched_target}
    else
      context
    end
  end
end
