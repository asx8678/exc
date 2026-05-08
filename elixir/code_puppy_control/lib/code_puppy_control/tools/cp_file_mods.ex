defmodule CodePuppyControl.Tools.CpFileMods do
  @moduledoc """
  `:cp_`-prefixed Tool-behaviour wrappers for file modification tools.

  These modules re-export the existing file modification tools under
  `:cp_`-prefixed names so the CodePuppy agent's `allowed_tools/0`
  resolves correctly through the Tool Registry.

  Each wrapper delegates both `permission_check/2` and `invoke/2` to the
  underlying tool module, preserving full tool functionality including
  security checks and schema validation.

  Refs: code_puppy-4s8.7 (Phase C CI gate)
  """

  defmodule CpCreateFile do
    @moduledoc "Create a new file or overwrite an existing one."
    use CodePuppyControl.Tool

    @impl true
    def name, do: :cp_create_file

    @impl true
    def description,
      do: CodePuppyControl.Tools.FileModifications.CreateFile.description()

    @impl true
    def parameters,
      do: CodePuppyControl.Tools.FileModifications.CreateFile.parameters()

    @impl true
    def permission_check(args, context),
      do: CodePuppyControl.Tools.FileModifications.CreateFile.permission_check(args, context)

    @impl true
    def invoke(args, context),
      do: CodePuppyControl.Tools.FileModifications.CreateFile.invoke(args, context)
  end

  defmodule CpReplaceInFile do
    @moduledoc "Apply targeted text replacements to an existing file."
    use CodePuppyControl.Tool

    @impl true
    def name, do: :cp_replace_in_file

    @impl true
    def description,
      do: CodePuppyControl.Tools.FileModifications.ReplaceInFile.description()

    @impl true
    def parameters,
      do: CodePuppyControl.Tools.FileModifications.ReplaceInFile.parameters()

    @impl true
    def permission_check(args, context),
      do: CodePuppyControl.Tools.FileModifications.ReplaceInFile.permission_check(args, context)

    @impl true
    def invoke(args, context),
      do: CodePuppyControl.Tools.FileModifications.ReplaceInFile.invoke(args, context)
  end

  defmodule CpEditFile do
    @moduledoc "Edit a file with targeted changes."
    use CodePuppyControl.Tool

    @impl true
    def name, do: :cp_edit_file

    @impl true
    def description,
      do: CodePuppyControl.Tools.FileModifications.EditFile.description()

    @impl true
    def parameters,
      do: CodePuppyControl.Tools.FileModifications.EditFile.parameters()

    @impl true
    def permission_check(args, context),
      do: CodePuppyControl.Tools.FileModifications.EditFile.permission_check(args, context)

    @impl true
    def invoke(args, context),
      do: CodePuppyControl.Tools.FileModifications.EditFile.invoke(args, context)
  end

  defmodule CpDeleteFile do
    @moduledoc "Delete a file from the project."
    use CodePuppyControl.Tool

    @impl true
    def name, do: :cp_delete_file

    @impl true
    def description,
      do: CodePuppyControl.Tools.FileModifications.DeleteFile.description()

    @impl true
    def parameters,
      do: CodePuppyControl.Tools.FileModifications.DeleteFile.parameters()

    @impl true
    def permission_check(args, context),
      do: CodePuppyControl.Tools.FileModifications.DeleteFile.permission_check(args, context)

    @impl true
    def invoke(args, context),
      do: CodePuppyControl.Tools.FileModifications.DeleteFile.invoke(args, context)
  end

  defmodule CpDeleteSnippet do
    @moduledoc "Remove a specific text snippet from a file."
    use CodePuppyControl.Tool

    @impl true
    def name, do: :cp_delete_snippet

    @impl true
    def description,
      do: CodePuppyControl.Tools.FileModifications.DeleteSnippet.description()

    @impl true
    def parameters,
      do: CodePuppyControl.Tools.FileModifications.DeleteSnippet.parameters()

    @impl true
    def permission_check(args, context),
      do: CodePuppyControl.Tools.FileModifications.DeleteSnippet.permission_check(args, context)

    @impl true
    def invoke(args, context),
      do: CodePuppyControl.Tools.FileModifications.DeleteSnippet.invoke(args, context)
  end
end
