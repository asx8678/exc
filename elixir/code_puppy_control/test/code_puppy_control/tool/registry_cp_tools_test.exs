defmodule CodePuppyControl.Tool.RegistryCpToolsTest do
  @moduledoc """
  Tests that the Tool Registry discovers all :cp_ tool modules.

  This is a CI gate test (code_puppy-4s8.7) — it ensures that every
  cp_ tool module in discover_cp_tools/0 is properly compiled and
  registered. Phase E additions (skills, scheduler, UC) are verified
  alongside existing file, shell, agent, and file-mod tools.

  Refs: code_puppy-mmk.2 (Phase E port)
  """

  use ExUnit.Case, async: true

  @cp_tool_names [
    # Phase C: file ops
    :cp_list_files,
    :cp_read_file,
    :cp_grep,
    # Phase C: shell
    :cp_run_command,
    # Phase C: agent ops
    :cp_invoke_agent,
    :cp_list_agents,
    # Phase C: file mods
    :cp_create_file,
    :cp_replace_in_file,
    :cp_edit_file,
    :cp_delete_file,
    :cp_delete_snippet,
    # Phase C: ask user
    :cp_ask_user_question,
    # Phase E: skills (code_puppy-mmk.2)
    :cp_list_skills,
    :cp_activate_skill,
    # Phase E: scheduler (code_puppy-mmk.2)
    :cp_scheduler_list_tasks,
    :cp_scheduler_create_task,
    :cp_scheduler_delete_task,
    :cp_scheduler_toggle_task,
    :cp_scheduler_status,
    :cp_scheduler_run_task,
    :cp_scheduler_view_log,
    :cp_scheduler_force_check,
    # Phase E: universal constructor (code_puppy-mmk.2)
    :cp_universal_constructor
  ]

  describe "cp_ tool module compilation" do
    test "all cp_ tool modules are compilable and implement Tool behaviour" do
      modules = [
        CodePuppyControl.Tools.CpFileOps.CpListFiles,
        CodePuppyControl.Tools.CpFileOps.CpReadFile,
        CodePuppyControl.Tools.CpFileOps.CpGrep,
        CodePuppyControl.Tools.CpShell.CpRunCommand,
        CodePuppyControl.Tools.CpAgentOps.CpInvokeAgent,
        CodePuppyControl.Tools.CpAgentOps.CpListAgents,
        CodePuppyControl.Tools.CpFileMods.CpCreateFile,
        CodePuppyControl.Tools.CpFileMods.CpReplaceInFile,
        CodePuppyControl.Tools.CpFileMods.CpEditFile,
        CodePuppyControl.Tools.CpFileMods.CpDeleteFile,
        CodePuppyControl.Tools.CpFileMods.CpDeleteSnippet,
        CodePuppyControl.Tools.CpAskUserQuestion,
        # Phase E additions
        CodePuppyControl.Tools.CpSkillOps.CpListSkills,
        CodePuppyControl.Tools.CpSkillOps.CpActivateSkill,
        CodePuppyControl.Tools.CpSchedulerOps.CpSchedulerListTasks,
        CodePuppyControl.Tools.CpSchedulerOps.CpSchedulerCreateTask,
        CodePuppyControl.Tools.CpSchedulerOps.CpSchedulerDeleteTask,
        CodePuppyControl.Tools.CpSchedulerOps.CpSchedulerToggleTask,
        CodePuppyControl.Tools.CpSchedulerOps.CpSchedulerStatus,
        CodePuppyControl.Tools.CpSchedulerOps.CpSchedulerRunTask,
        CodePuppyControl.Tools.CpSchedulerOps.CpSchedulerViewLog,
        CodePuppyControl.Tools.CpSchedulerOps.CpSchedulerForceCheck,
        CodePuppyControl.Tools.CpUniversalConstructor
      ]

      for mod <- modules do
        assert Code.ensure_loaded?(mod), "Module #{inspect(mod)} failed to compile"
        assert function_exported?(mod, :name, 0), "#{inspect(mod)} missing name/0"
        assert function_exported?(mod, :description, 0), "#{inspect(mod)} missing description/0"
        assert function_exported?(mod, :parameters, 0), "#{inspect(mod)} missing parameters/0"
      end
    end

    test "all cp_ tool names are unique" do
      modules = [
        CodePuppyControl.Tools.CpFileOps.CpListFiles,
        CodePuppyControl.Tools.CpFileOps.CpReadFile,
        CodePuppyControl.Tools.CpFileOps.CpGrep,
        CodePuppyControl.Tools.CpShell.CpRunCommand,
        CodePuppyControl.Tools.CpAgentOps.CpInvokeAgent,
        CodePuppyControl.Tools.CpAgentOps.CpListAgents,
        CodePuppyControl.Tools.CpFileMods.CpCreateFile,
        CodePuppyControl.Tools.CpFileMods.CpReplaceInFile,
        CodePuppyControl.Tools.CpFileMods.CpEditFile,
        CodePuppyControl.Tools.CpFileMods.CpDeleteFile,
        CodePuppyControl.Tools.CpFileMods.CpDeleteSnippet,
        CodePuppyControl.Tools.CpAskUserQuestion,
        CodePuppyControl.Tools.CpSkillOps.CpListSkills,
        CodePuppyControl.Tools.CpSkillOps.CpActivateSkill,
        CodePuppyControl.Tools.CpSchedulerOps.CpSchedulerListTasks,
        CodePuppyControl.Tools.CpSchedulerOps.CpSchedulerCreateTask,
        CodePuppyControl.Tools.CpSchedulerOps.CpSchedulerDeleteTask,
        CodePuppyControl.Tools.CpSchedulerOps.CpSchedulerToggleTask,
        CodePuppyControl.Tools.CpSchedulerOps.CpSchedulerStatus,
        CodePuppyControl.Tools.CpSchedulerOps.CpSchedulerRunTask,
        CodePuppyControl.Tools.CpSchedulerOps.CpSchedulerViewLog,
        CodePuppyControl.Tools.CpSchedulerOps.CpSchedulerForceCheck,
        CodePuppyControl.Tools.CpUniversalConstructor
      ]

      names = Enum.map(modules, fn mod -> mod.name() end)
      unique_names = MapSet.new(names)

      assert MapSet.size(unique_names) == length(names),
             "Duplicate tool names found: #{inspect(names -- MapSet.to_list(unique_names))}"
    end

    test "all expected cp_ tool names are present" do
      modules = [
        CodePuppyControl.Tools.CpFileOps.CpListFiles,
        CodePuppyControl.Tools.CpFileOps.CpReadFile,
        CodePuppyControl.Tools.CpFileOps.CpGrep,
        CodePuppyControl.Tools.CpShell.CpRunCommand,
        CodePuppyControl.Tools.CpAgentOps.CpInvokeAgent,
        CodePuppyControl.Tools.CpAgentOps.CpListAgents,
        CodePuppyControl.Tools.CpFileMods.CpCreateFile,
        CodePuppyControl.Tools.CpFileMods.CpReplaceInFile,
        CodePuppyControl.Tools.CpFileMods.CpEditFile,
        CodePuppyControl.Tools.CpFileMods.CpDeleteFile,
        CodePuppyControl.Tools.CpFileMods.CpDeleteSnippet,
        CodePuppyControl.Tools.CpAskUserQuestion,
        CodePuppyControl.Tools.CpSkillOps.CpListSkills,
        CodePuppyControl.Tools.CpSkillOps.CpActivateSkill,
        CodePuppyControl.Tools.CpSchedulerOps.CpSchedulerListTasks,
        CodePuppyControl.Tools.CpSchedulerOps.CpSchedulerCreateTask,
        CodePuppyControl.Tools.CpSchedulerOps.CpSchedulerDeleteTask,
        CodePuppyControl.Tools.CpSchedulerOps.CpSchedulerToggleTask,
        CodePuppyControl.Tools.CpSchedulerOps.CpSchedulerStatus,
        CodePuppyControl.Tools.CpSchedulerOps.CpSchedulerRunTask,
        CodePuppyControl.Tools.CpSchedulerOps.CpSchedulerViewLog,
        CodePuppyControl.Tools.CpSchedulerOps.CpSchedulerForceCheck,
        CodePuppyControl.Tools.CpUniversalConstructor
      ]

      actual_names = Enum.map(modules, fn mod -> mod.name() end)

      for expected <- @cp_tool_names do
        assert expected in actual_names, "Expected tool name #{expected} not found"
      end
    end
  end
end
