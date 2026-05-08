defmodule CodePuppyControl.Tools.CpSkillOps do
  @moduledoc """
  `:cp_`-prefixed Tool-behaviour wrappers for skill tools.

  These modules re-export the skill tools under `:cp_`-prefixed names
  so the CodePuppy agent's `allowed_tools/0` resolves correctly through
  the Tool Registry.

  Each wrapper delegates `invoke/2` to the underlying skill tool module,
  preserving full functionality including config checks, disabled filtering,
  and EventBus emission.

  ## Tools

  - `CpListSkills` — List available skills, optionally filtered by query
  - `CpActivateSkill` — Activate a skill by loading its SKILL.md

  Refs: code_puppy-mmk.2 (Phase E port)
  """

  defmodule CpListSkills do
    @moduledoc "List available skills, optionally filtered by search query."
    use CodePuppyControl.Tool

    alias CodePuppyControl.Tools.Skills.ListSkills

    @impl true
    def name, do: :cp_list_skills

    @impl true
    def description, do: ListSkills.description()

    @impl true
    def parameters, do: ListSkills.parameters()

    @impl true
    def invoke(args, context), do: ListSkills.invoke(args, context)
  end

  defmodule CpActivateSkill do
    @moduledoc "Activate a skill by loading its full SKILL.md instructions."
    use CodePuppyControl.Tool

    alias CodePuppyControl.Tools.Skills.ActivateSkill

    @impl true
    def name, do: :cp_activate_skill

    @impl true
    def description, do: ActivateSkill.description()

    @impl true
    def parameters, do: ActivateSkill.parameters()

    @impl true
    def invoke(args, context), do: ActivateSkill.invoke(args, context)
  end
end
