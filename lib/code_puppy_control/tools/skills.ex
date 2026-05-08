defmodule CodePuppyControl.Tools.Skills do
  @moduledoc """
  Skills tools — dedicated tools for Agent Skills integration.

  Provides two tools:

  - `list_skills` — List available skills, optionally filtered by search query
  - `activate_skill` — Activate a skill by loading its full SKILL.md instructions

  Skills are discovered from configured skill directories (typically
  `~/.code_puppy_ex/skills/` and `./skills/`). Each skill must have a SKILL.md file.

  ## Design

  This module ports behavior from `code_puppy/tools/skills_tools.py`. It
  respects the `skills_enabled` config flag and `disabled_skills` list, emits
  events via `EventBus`, and returns output shapes matching the Python
  `SkillListOutput` / `SkillActivateOutput` contracts (with `error` field).

  ## Config keys in `puppy.cfg`

  - `skills_enabled` — master toggle (default `true`)
  - `disabled_skills` — comma-separated list of skill names to exclude
  """

  require Logger

  alias CodePuppyControl.Config.Paths
  alias CodePuppyControl.Tool.Registry

  # ── Config helpers ─────────────────────────────────────────────────────

  @doc "Returns true if skills integration is enabled (default true)."
  @spec skills_enabled?() :: boolean()
  def skills_enabled?, do: CodePuppyControl.Config.Debug.skills_enabled?()

  @doc "Returns the list of disabled skill names from config."
  @spec disabled_skills() :: [String.t()]
  def disabled_skills do
    case CodePuppyControl.Config.Loader.get_value("disabled_skills") do
      nil ->
        []

      "" ->
        []

      val when is_binary(val) ->
        val
        |> String.split(",", trim: true)
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))

      _ ->
        []
    end
  end

  defmodule ListSkills do
    @moduledoc "List available skills, optionally filtered by search query."

    use CodePuppyControl.Tool

    @impl true
    def name, do: :list_skills

    @impl true
    def description do
      "List available skills, optionally filtered by search query. " <>
        "Returns skill names, descriptions, paths, and tags."
    end

    @impl true
    def parameters do
      %{
        "type" => "object",
        "properties" => %{
          "query" => %{
            "type" => "string",
            "description" =>
              "Optional search term to filter skills by name/description/tags. " <>
                "If omitted, returns all available skills."
          }
        },
        "required" => []
      }
    end

    @impl true
    def invoke(args, _context) do
      query = Map.get(args, "query")

      # Check if skills are enabled (matches Python behavior)
      unless CodePuppyControl.Tools.Skills.skills_enabled?() do
        {:ok,
         %{
           skills: [],
           total_count: 0,
           query: query,
           error: "Skills integration is disabled. Enable it with /set skills_enabled=true"
         }}
      else
        do_invoke(query)
      end
    end

    defp do_invoke(query) do
      disabled = CodePuppyControl.Tools.Skills.disabled_skills()
      skill_dirs = get_skill_dirs()

      try do
        skills =
          skill_dirs
          |> discover_skills()
          |> Enum.reject(fn skill -> skill.name in disabled end)
          |> filter_skills(query)

        # Emit event via EventBus
        emit_list_event(skills, query)

        {:ok,
         %{
           skills: skills,
           total_count: length(skills),
           query: query,
           error: nil
         }}
      rescue
        e ->
          Logger.error("Failed to discover skills: #{inspect(e)}")

          {:ok,
           %{
             skills: [],
             total_count: 0,
             query: query,
             error: "Failed to discover skills: #{Exception.message(e)}"
           }}
      end
    end

    defp emit_list_event(skills, query) do
      event = %{
        type: "tool_output",
        tool: "list_skills",
        data: %{
          skills: Enum.map(skills, &Map.take(&1, [:name, :description, :path, :tags])),
          query: query,
          total_count: length(skills)
        }
      }

      CodePuppyControl.EventBus.broadcast_event(event)
    end

    defp get_skill_dirs do
      [Paths.skills_dir(), Path.join(File.cwd!(), "skills")]
      |> Enum.filter(&File.dir?/1)
    end

    defp discover_skills(dirs) do
      Enum.flat_map(dirs, fn dir ->
        case File.ls(dir) do
          {:ok, entries} ->
            Enum.flat_map(entries, fn entry ->
              skill_dir = Path.join(dir, entry)
              skill_md = Path.join(skill_dir, "SKILL.md")

              if File.dir?(skill_dir) and File.exists?(skill_md) do
                metadata = parse_skill_metadata(skill_dir, skill_md)
                [metadata]
              else
                []
              end
            end)

          {:error, _} ->
            []
        end
      end)
    end

    defp parse_skill_metadata(skill_dir, skill_md) do
      case File.read(skill_md) do
        {:ok, content} ->
          %{
            name: Path.basename(skill_dir),
            description: extract_description(content),
            path: skill_dir,
            tags: extract_tags(content),
            version: extract_version(content),
            author: extract_author(content)
          }

        {:error, _} ->
          %{
            name: Path.basename(skill_dir),
            description: "",
            path: skill_dir,
            tags: [],
            version: nil,
            author: nil
          }
      end
    end

    defp extract_description(content) do
      content
      |> String.split("\n")
      |> Enum.drop_while(&(&1 == ""))
      |> Enum.take_while(&(not String.starts_with?(&1, "#")))
      |> Enum.join(" ")
      |> String.trim()
      |> String.slice(0, 200)
    end

    defp extract_tags(content) do
      case Regex.run(~r/tags:\s*\[(.*?)\]/, content) do
        [_, tags_str] ->
          tags_str
          |> String.split(",")
          |> Enum.map(&String.trim/1)
          |> Enum.map(&String.trim(&1, "\""))
          |> Enum.reject(&(&1 == ""))

        _ ->
          []
      end
    end

    defp extract_version(content) do
      case Regex.run(~r/version:\s*"?([^"\n]+)"?/, content) do
        [_, version] -> String.trim(version)
        _ -> nil
      end
    end

    defp extract_author(content) do
      case Regex.run(~r/author:\s*"?([^"\n]+)"?/, content) do
        [_, author] -> String.trim(author)
        _ -> nil
      end
    end

    defp filter_skills(skills, nil), do: skills
    defp filter_skills(skills, ""), do: skills

    defp filter_skills(skills, query) do
      query_lower = String.downcase(query)

      Enum.filter(skills, fn skill ->
        String.contains?(String.downcase(skill.name), query_lower) or
          String.contains?(String.downcase(skill.description), query_lower) or
          Enum.any?(skill.tags, &String.contains?(String.downcase(&1), query_lower))
      end)
    end
  end

  defmodule ActivateSkill do
    @moduledoc "Activate a skill by loading its full SKILL.md instructions."

    use CodePuppyControl.Tool

    @impl true
    def name, do: :activate_skill

    @impl true
    def description do
      "Activate a skill by loading its full SKILL.md instructions. " <>
        "Returns the skill content and available resource files."
    end

    @impl true
    def parameters do
      %{
        "type" => "object",
        "properties" => %{
          "skill_name" => %{
            "type" => "string",
            "description" => "Name of the skill to activate"
          }
        },
        "required" => ["skill_name"]
      }
    end

    @impl true
    def invoke(args, _context) do
      skill_name = Map.get(args, "skill_name", "")

      # Check if skills are enabled (matches Python behavior)
      unless CodePuppyControl.Tools.Skills.skills_enabled?() do
        {:ok,
         %{
           skill_name: skill_name,
           content: nil,
           resources: [],
           error: "Skills integration is disabled. Enable it with /set skills_enabled=true"
         }}
      else
        # Guard against path traversal — reject skill names containing
        # '/', '\\', '..' components or absolute paths
        if skill_name_has_traversal?(skill_name) do
          {:ok,
           %{
             skill_name: skill_name,
             content: nil,
             resources: [],
             error: "Invalid skill name: '#{skill_name}' contains path traversal characters"
           }}
        else
          do_invoke(skill_name)
        end
      end
    end

    # Rejects skill names that could traverse outside skill directories.
    # Matches Python security posture: no '/', '\\', '..' or absolute paths.
    defp skill_name_has_traversal?(name) when is_binary(name) do
      String.contains?(name, "/") or
        String.contains?(name, "\\") or
        String.contains?(name, "..") or
        (byte_size(name) > 0 and :binary.first(name) == ?/)
    end

    defp skill_name_has_traversal?(_), do: true

    defp do_invoke(skill_name) do
      case find_skill(skill_name) do
        {:ok, skill_path, content, resources} ->
          # Emit activation event
          content_preview = String.slice(content, 0, 200)
          emit_activate_event(skill_name, skill_path, content_preview, length(resources))

          {:ok,
           %{
             skill_name: skill_name,
             content: content,
             resources: resources,
             skill_path: skill_path,
             error: nil
           }}

        {:error, reason} ->
          # Expected failure: skill not found or read error.
          # Return ok with SkillActivateOutput shape (error field populated)
          # rather than {:error, reason} to preserve Python contract.
          {:ok,
           %{
             skill_name: skill_name,
             content: nil,
             resources: [],
             error: reason
           }}
      end
    end

    defp emit_activate_event(skill_name, skill_path, content_preview, resource_count) do
      event = %{
        type: "tool_output",
        tool: "activate_skill",
        data: %{
          skill_name: skill_name,
          skill_path: skill_path,
          content_preview: content_preview,
          resource_count: resource_count,
          success: true
        }
      }

      CodePuppyControl.EventBus.broadcast_event(event)
    end

    defp find_skill(skill_name) do
      skill_dirs = get_skill_dirs()

      Enum.reduce_while(
        skill_dirs,
        {:error, "Skill '#{skill_name}' not found. Use list_skills to see available skills."},
        fn dir, acc ->
          skill_dir = Path.join(dir, skill_name)
          skill_md = Path.join(skill_dir, "SKILL.md")

          if File.dir?(skill_dir) and File.exists?(skill_md) do
            case File.read(skill_md) do
              {:ok, content} ->
                resources = get_resources(skill_dir)
                {:halt, {:ok, skill_dir, content, resources}}

              {:error, reason} ->
                {:halt, {:error, "Failed to read SKILL.md: #{:file.format_error(reason)}"}}
            end
          else
            {:cont, acc}
          end
        end
      )
    end

    defp get_resources(skill_dir) do
      case File.ls(skill_dir) do
        {:ok, entries} ->
          entries
          |> Enum.map(&Path.join(skill_dir, &1))
          |> Enum.filter(&File.regular?/1)
          |> Enum.map(&to_string/1)

        {:error, _} ->
          []
      end
    end

    defp get_skill_dirs do
      [Paths.skills_dir(), Path.join(File.cwd!(), "skills")]
      |> Enum.filter(&File.dir?/1)
    end
  end

  @doc """
  Registers both skill tools with the Tool Registry.
  """
  @spec register_all() :: {:ok, non_neg_integer()}
  def register_all do
    modules = [ListSkills, ActivateSkill]

    Enum.reduce(modules, {:ok, 0}, fn module, {:ok, acc} ->
      case Registry.register(module) do
        :ok -> {:ok, acc + 1}
        {:error, _} -> {:ok, acc}
      end
    end)
  end
end
