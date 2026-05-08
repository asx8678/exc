defmodule CodePuppyControl.Config.Importer do
  @moduledoc """
  Import non-sensitive settings from the Python pup's legacy home.

  Copies allowlisted files from `~/.code_puppy/` to `~/.code_puppy_ex/`.
  All reads go through `Isolation.read_only_legacy/1`; all writes go
  through `Isolation.safe_write!/2` and `Isolation.safe_mkdir_p!/1`.

  Run without `--confirm` for dry-run mode (shows what WOULD be copied).
  Add `--confirm` to actually copy. Add `--force` to overwrite existing files.
  """

  alias CodePuppyControl.Config.{Isolation, Paths, Loader}

  @type result :: %{
          mode: :dry_run | :copy | :no_op,
          copied: [String.t()],
          skipped: [{String.t(), String.t()}],
          refused: [{String.t(), String.t()}],
          errors: [{String.t(), term()}]
        }

  # ── Forbidden patterns (ADR-003 default-deny) ──────────────────────────

  @forbidden_filename_patterns ~w(oauth token _auth)
  @forbidden_extensions ~w(.sqlite .db)
  @forbidden_dirs ~w(autosaves sessions)
  @forbidden_files ~w(command_history.txt)
  @forbidden_key_patterns ~w(auth token api_key api_secret secret password credential session_key)

  # ── Public API ──────────────────────────────────────────────────────────

  @doc """
  Run the import process.

  Options:
    - `:confirm` — actually copy files (dry-run without it)
    - `:force` — overwrite existing files at destination
    - `:__legacy_home__` — internal: override legacy home path (for testing)
  """
  @spec run(keyword()) :: result()
  def run(opts) do
    legacy_home = Keyword.get(opts, :__legacy_home__, Paths.legacy_home_dir())

    if not File.dir?(legacy_home) do
      %{mode: :no_op, copied: [], skipped: [], refused: [], errors: []}
    else
      mode = if Keyword.get(opts, :confirm, false), do: :copy, else: :dry_run
      force = Keyword.get(opts, :force, false)

      {copied, skipped, refused, errors} =
        {[], [], [], []}
        |> scan_for_forbidden(legacy_home)
        |> import_extra_models(legacy_home, mode, force)
        |> import_models_json(legacy_home, mode, force)
        |> import_puppy_cfg(legacy_home, mode, force)
        |> import_agents(legacy_home, mode, force)
        |> import_skills(legacy_home, mode, force)

      %{mode: mode, copied: copied, skipped: skipped, refused: refused, errors: errors}
    end
  end

  @doc """
  Read a file from the legacy home using the sanctioned read path.

  Delegates to `Isolation.read_only_legacy/1` when the path is under
  the real legacy home; falls back to `File.read/1` for test overrides.
  """
  @spec read_from_legacy(String.t()) :: {:ok, binary()} | {:error, term()}
  def read_from_legacy(path) do
    if Paths.in_legacy_home?(path) do
      Isolation.read_only_legacy(path)
    else
      File.read(path)
    end
  end

  @doc """
  Returns `true` if the given source path (relative to legacy home) is
  allowed to be imported per the ADR-003 allowlist.
  """
  @spec allowed_source?(String.t()) :: boolean()
  def allowed_source?(rel_path) do
    basename = Path.basename(rel_path)

    cond do
      # Forbidden filename patterns
      Enum.any?(@forbidden_filename_patterns, &String.contains?(String.downcase(basename), &1)) ->
        false

      # Forbidden extensions
      Enum.any?(@forbidden_extensions, &String.ends_with?(String.downcase(basename), &1)) ->
        false

      # Forbidden directories (check if the path goes through one)
      Enum.any?(@forbidden_dirs, fn dir ->
        String.contains?("/#{rel_path}/", "/#{dir}/")
      end) ->
        false

      # Forbidden exact filenames
      basename in @forbidden_files ->
        false

      # Allowlist check
      true ->
        rel_path in ~w(extra_models.json models.json puppy.cfg) or
          String.starts_with?(rel_path, "agents/") or
          String.starts_with?(rel_path, "skills/")
    end
  end

  @doc """
  Returns `true` if the given relative path is forbidden per ADR-003.
  A file is forbidden if it matches a denial pattern AND is not in the
  explicit allowlist. Files that are neither allowed nor forbidden are
  "unknown" (default-deny, but not explicitly refused).
  """
  @spec forbidden_source?(String.t()) :: boolean()
  def forbidden_source?(rel_path) do
    basename = Path.basename(rel_path)

    cond do
      # Forbidden filename patterns
      Enum.any?(@forbidden_filename_patterns, &String.contains?(String.downcase(basename), &1)) ->
        true

      # Forbidden extensions
      Enum.any?(@forbidden_extensions, &String.ends_with?(String.downcase(basename), &1)) ->
        true

      # Forbidden directories
      Enum.any?(@forbidden_dirs, fn dir ->
        String.contains?("/#{rel_path}/", "/#{dir}/")
      end) ->
        true

      # Forbidden exact filenames
      basename in @forbidden_files ->
        true

      true ->
        false
    end
  end

  # ── Scan phase: discover forbidden files ────────────────────────────────

  defp scan_for_forbidden(acc, legacy_home) do
    {copied, skipped, refused, errors} = acc

    found_forbidden =
      legacy_home
      |> walk_dir("")
      |> Enum.filter(&forbidden_source?/1)
      |> Enum.map(fn rel -> {Path.join(legacy_home, rel), "forbidden by ADR-003 allowlist"} end)

    {copied, skipped, found_forbidden ++ refused, errors}
  end

  defp walk_dir(root, prefix) do
    dir = if prefix == "", do: root, else: Path.join(root, prefix)

    case File.ls(dir) do
      {:ok, entries} ->
        Enum.flat_map(entries, fn entry ->
          rel = if prefix == "", do: entry, else: "#{prefix}/#{entry}"
          full = Path.join(dir, entry)

          cond do
            File.dir?(full) ->
              walk_dir(root, rel)

            File.regular?(full) ->
              [rel]

            true ->
              []
          end
        end)

      {:error, _} ->
        []
    end
  end

  # ── Import pipeline (accumulates results) ───────────────────────────────

  defp import_extra_models(acc, legacy_home, mode, force) do
    src = Path.join(legacy_home, "extra_models.json")
    dst = Paths.extra_models_file()

    import_single_file(src, dst, "extra_models.json", mode, force, acc)
  end

  defp import_models_json(acc, legacy_home, mode, force) do
    src = Path.join(legacy_home, "models.json")
    dst = Paths.models_file()

    if File.exists?(src) do
      {copied, skipped, refused, errors} = acc

      case read_from_legacy(src) do
        {:ok, legacy_json} ->
          case Jason.decode(legacy_json) do
            {:ok, legacy_data} ->
              existing_data = read_existing_json(dst)
              merged = deep_merge_preserving_existing(existing_data, legacy_data)
              merged_json = Jason.encode!(merged, pretty: true)

              if not force and File.exists?(dst) do
                {copied, [{dst, "already exists; use --force to overwrite"} | skipped], refused,
                 errors}
              else
                case maybe_write(dst, merged_json, mode) do
                  :ok -> {[dst | copied], skipped, refused, errors}
                  {:error, reason} -> {copied, skipped, refused, [{dst, reason} | errors]}
                end
              end

            {:error, reason} ->
              {copied, skipped, refused, [{"models.json", reason} | errors]}
          end

        {:error, :enoent} ->
          acc

        {:error, reason} ->
          {copied, skipped, refused, [{"models.json", reason} | errors]}
      end
    else
      acc
    end
  end

  defp import_puppy_cfg(acc, legacy_home, mode, force) do
    src = Path.join(legacy_home, "puppy.cfg")
    dst = Paths.config_file()

    if File.exists?(src) do
      {copied, skipped, refused, errors} = acc

      case read_from_legacy(src) do
        {:ok, content} ->
          # Parse the legacy INI and extract only the [ui] section
          legacy_config = Loader.parse_string(content)
          ui_section = Map.get(legacy_config, "ui", %{})

          # Filter out any forbidden keys
          safe_ui =
            ui_section
            |> Enum.reject(fn {k, _v} -> forbidden_key?(k) end)
            |> Map.new()

          if map_size(safe_ui) == 0 do
            acc
          else
            existing_config = Loader.parse_file(dst)
            existing_ui = Map.get(existing_config, "ui", %{})
            merged_ui = Map.merge(existing_ui, safe_ui)
            merged_config = Map.put(existing_config, "ui", merged_ui)

            serialized = serialize_ini(merged_config)

            if not force and map_size(existing_ui) > 0 and existing_ui == safe_ui do
              {copied, [{dst, "ui section already matches"} | skipped], refused, errors}
            else
              case maybe_write(dst, serialized, mode) do
                :ok -> {[dst | copied], skipped, refused, errors}
                {:error, reason} -> {copied, skipped, refused, [{dst, reason} | errors]}
              end
            end
          end

        {:error, :enoent} ->
          acc

        {:error, reason} ->
          {copied, skipped, refused, [{"puppy.cfg", reason} | errors]}
      end
    else
      acc
    end
  end

  defp import_agents(acc, legacy_home, mode, force) do
    src_dir = Path.join(legacy_home, "agents")
    dst_dir = Paths.agents_dir()

    if File.dir?(src_dir) do
      import_directory(src_dir, dst_dir, ".json", "agents", mode, force, acc)
    else
      acc
    end
  end

  defp import_skills(acc, legacy_home, mode, force) do
    src_dir = Path.join(legacy_home, "skills")
    dst_dir = Paths.skills_dir()

    if File.dir?(src_dir) do
      case File.ls(src_dir) do
        {:ok, entries} ->
          Enum.reduce(entries, acc, fn entry, inner_acc ->
            src_sub = Path.join(src_dir, entry)
            dst_sub = Path.join(dst_dir, entry)

            if File.dir?(src_sub) do
              skill_md = Path.join(src_sub, "SKILL.md")

              if File.exists?(skill_md) do
                copy_directory_tree(src_sub, dst_sub, mode, force, inner_acc)
              else
                inner_acc
              end
            else
              inner_acc
            end
          end)

        {:error, _} ->
          acc
      end
    else
      acc
    end
  end

  # ── Helpers ─────────────────────────────────────────────────────────────

  defp import_single_file(src, dst, label, mode, force, acc) do
    if File.exists?(src) do
      {copied, skipped, refused, errors} = acc

      if not allowed_source?(label) do
        # Already handled by scan_for_forbidden, skip here
        acc
      else
        case read_from_legacy(src) do
          {:ok, content} ->
            if not force and File.exists?(dst) do
              {copied, [{dst, "already exists; use --force to overwrite"} | skipped], refused,
               errors}
            else
              case maybe_write(dst, content, mode) do
                :ok -> {[dst | copied], skipped, refused, errors}
                {:error, reason} -> {copied, skipped, refused, [{dst, reason} | errors]}
              end
            end

          {:error, :enoent} ->
            acc

          {:error, reason} ->
            {copied, skipped, refused, [{label, reason} | errors]}
        end
      end
    else
      acc
    end
  end

  defp import_directory(src_dir, dst_dir, ext_filter, prefix, mode, force, acc) do
    case File.ls(src_dir) do
      {:ok, entries} ->
        Enum.reduce(entries, acc, fn entry, inner_acc ->
          src_path = Path.join(src_dir, entry)

          if File.regular?(src_path) and Path.extname(entry) == ext_filter do
            dst_path = Path.join(dst_dir, entry)
            rel_path = "#{prefix}/#{entry}"
            {copied, skipped, refused, errors} = inner_acc

            if not allowed_source?(rel_path) do
              # Already handled by scan_for_forbidden
              inner_acc
            else
              if not force and File.exists?(dst_path) do
                {copied, [{dst_path, "already exists"} | skipped], refused, errors}
              else
                case read_from_legacy(src_path) do
                  {:ok, content} ->
                    case maybe_write(dst_path, content, mode) do
                      :ok ->
                        {[dst_path | copied], skipped, refused, errors}

                      {:error, reason} ->
                        {copied, skipped, refused, [{dst_path, reason} | errors]}
                    end

                  {:error, reason} ->
                    {copied, skipped, refused, [{entry, reason} | errors]}
                end
              end
            end
          else
            inner_acc
          end
        end)

      {:error, _} ->
        acc
    end
  end

  defp copy_directory_tree(src_dir, dst_dir, mode, force, acc) do
    {copied, skipped, refused, errors} = acc

    if not force and File.dir?(dst_dir) do
      {copied, [{dst_dir, "already exists; use --force to overwrite"} | skipped], refused, errors}
    else
      case walk_and_copy(src_dir, dst_dir, mode, force) do
        {:ok, paths} ->
          {paths ++ copied, skipped, refused, errors}

        {:error, reason} ->
          {copied, skipped, refused, [{dst_dir, reason} | errors]}
      end
    end
  end

  defp walk_and_copy(src_dir, dst_dir, mode, force) do
    case File.ls(src_dir) do
      {:ok, entries} ->
        {copied, errors} =
          Enum.reduce(entries, {[], []}, fn entry, {c, e} ->
            src_path = Path.join(src_dir, entry)
            dst_path = Path.join(dst_dir, entry)

            cond do
              File.dir?(src_path) ->
                case walk_and_copy(src_path, dst_path, mode, force) do
                  {:ok, paths} -> {paths ++ c, e}
                  {:error, reason} -> {c, [{dst_path, reason} | e]}
                end

              File.regular?(src_path) ->
                case read_from_legacy(src_path) do
                  {:ok, content} ->
                    if not force and File.exists?(dst_path) do
                      {c, e}
                    else
                      case maybe_write(dst_path, content, mode) do
                        :ok -> {[dst_path | c], e}
                        {:error, reason} -> {c, [{dst_path, reason} | e]}
                      end
                    end

                  {:error, reason} ->
                    {c, [{entry, reason} | e]}
                end

              true ->
                {c, e}
            end
          end)

        if errors == [], do: {:ok, copied}, else: {:error, errors}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp maybe_write(_path, _content, :dry_run), do: :ok

  defp maybe_write(path, content, :copy) do
    try do
      dir = Path.dirname(path)
      Isolation.safe_mkdir_p!(dir)
      Isolation.safe_write!(path, content)
      :ok
    rescue
      e -> {:error, Exception.message(e)}
    end
  end

  defp read_existing_json(path) do
    case File.read(path) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, data} -> data
          {:error, _} -> %{}
        end

      {:error, _} ->
        %{}
    end
  end

  defp deep_merge_preserving_existing(existing, legacy)
       when is_map(existing) and is_map(legacy) do
    Map.merge(legacy, existing, fn _k, v_existing, _v_legacy -> v_existing end)
  end

  defp deep_merge_preserving_existing(existing, _legacy), do: existing

  defp forbidden_key?(key) do
    lower = String.downcase(key)
    Enum.any?(@forbidden_key_patterns, &String.contains?(lower, &1))
  end

  defp serialize_ini(config) do
    config
    |> Enum.sort_by(fn {section, _} -> section end)
    |> Enum.map_join("\n", fn {section, kv_map} ->
      section_header = "[#{section}]"

      pairs =
        kv_map
        |> Enum.sort_by(fn {k, _} -> k end)
        |> Enum.map_join("\n", fn {k, v} -> "#{k} = #{v}" end)

      "#{section_header}\n#{pairs}"
    end)
    |> then(&(&1 <> "\n"))
  end
end
