defmodule CodePuppyControl.BurritoSteps.PatchMuslQualifierTest do
  use ExUnit.Case, async: true

  alias CodePuppyControl.BurritoSteps.PatchMuslQualifier
  alias Burrito.Builder.Context
  alias Burrito.Builder.Target

  describe "execute/1" do
    test "patches qualifiers[:os] to :linux when musl: true is set" do
      target = Target.init_target(:linux_musl_x86_64, os: :linux, cpu: :x86_64, musl: true)

      context = %Context{
        target: target,
        mix_release: nil,
        work_dir: "",
        self_dir: "",
        extra_build_env: [],
        halted: false
      }

      result = PatchMuslQualifier.execute(context)

      assert result.target.qualifiers[:os] == :linux
      assert result.target.qualifiers[:musl] == true
    end

    test "does not patch qualifiers for non-musl targets" do
      target = Target.init_target(:linux_x86_64, os: :linux, cpu: :x86_64)

      context = %Context{
        target: target,
        mix_release: nil,
        work_dir: "",
        self_dir: "",
        extra_build_env: [],
        halted: false
      }

      result = PatchMuslQualifier.execute(context)

      assert result.target.qualifiers[:os] == nil
    end

    test "produces correct musl triplet after patching" do
      %Target{} =
        target = Target.init_target(:linux_musl_x86_64, os: :linux, cpu: :x86_64, musl: true)

      patched_qualifiers = Keyword.put(target.qualifiers, :os, :linux)
      patched_target = %{target | qualifiers: patched_qualifiers}

      triplet = Target.make_triplet(patched_target)
      assert triplet == "x86_64-linux-musl"
    end

    test "produces correct arm64 musl triplet after patching" do
      %Target{} =
        target = Target.init_target(:linux_musl_arm64, os: :linux, cpu: :aarch64, musl: true)

      patched_qualifiers = Keyword.put(target.qualifiers, :os, :linux)
      patched_target = %{target | qualifiers: patched_qualifiers}

      triplet = Target.make_triplet(patched_target)
      assert triplet == "aarch64-linux-musl"
    end

    test "glibc targets keep non-musl triplet" do
      target = Target.init_target(:linux_x86_64, os: :linux, cpu: :x86_64)
      triplet = Target.make_triplet(target)
      assert triplet == "x86_64-linux"
    end
  end
end
