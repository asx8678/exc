defmodule CodePuppyControl.Tools.UniversalConstructor.Registry do
  @moduledoc """
  Registry for discovering and managing Universal Constructor tools.

  Scans the user's UC directory for Elixir modules (.ex files), extracts
  tool metadata from @uc_tool module attributes, and provides access to
  enabled tools.

  Supports namespacing via subdirectories:
  - `api/weather.ex` → namespace="api", name="weather", full_name="api.weather"

  ## TOOL_META Format in Elixir

  Tools define metadata via module attributes:

      defmodule MyTool do
        @uc_tool %{
          name: "my_tool",
          namespace: "",
          description: "Does something useful",
          enabled: true,
          version: "1.0.0",
          author: "user",
          created_at: "2024-01-15T10:30:00Z"
        }

        def run(args) do
          # Tool implementation
        end
      end
  """

  use GenServer

  require Logger

  alias CodePuppyControl.Config.Isolation
  alias CodePuppyControl.Config.Paths
  alias CodePuppyControl.Tools.UniversalConstructor.Models
  alias CodePuppyControl.Tools.UniversalConstructor.Validator

  # ============================================================================
  # Client API
  # ============================================================================

  def start_link(opts \\ []) do
    # Support custom name for testing (avoid GenServer collisions)
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent
    }
  end

  @doc """
  Lists all discovered UC tools.

  ## Options

    * `:include_disabled` - Whether to include disabled tools (default: false)

  """
  @spec list_tools(keyword()) :: list(Models.uc_tool_info())
  def list_tools(opts \\ []) do
    GenServer.call(__MODULE__, {:list_tools, opts})
  end

  @doc """
  Gets a specific tool by full name.

  ## Examples

      iex> Registry.get_tool("api.weather")
      %{meta: %{name: "weather", namespace: "api", ...}, ...}

  """
  @spec get_tool(String.t()) :: Models.uc_tool_info() | nil
  def get_tool(full_name) do
    GenServer.call(__MODULE__, {:get_tool, full_name})
  end

  @doc """
  Gets the function reference for a tool by full name.

  Returns `{module, function_name}` tuple or nil if not found.
  """
  @spec get_tool_function(String.t()) :: {module(), atom()} | nil
  def get_tool_function(full_name) do
    GenServer.call(__MODULE__, {:get_tool_function, full_name})
  end

  @doc """
  Reloads the registry by rescanning the tools directory.

  Returns the number of tools found.
  """
  @spec reload() :: non_neg_integer()
  def reload do
    GenServer.call(__MODULE__, :reload)
  end

  @doc """
  Ensures the tools directory exists, creating it if necessary.
  """
  @spec ensure_tools_dir() :: String.t()
  def ensure_tools_dir do
    GenServer.call(__MODULE__, :ensure_tools_dir)
  end

  @doc """
  Gets the configured tools directory path.
  """
  @spec tools_dir() :: String.t()
  def tools_dir do
    GenServer.call(__MODULE__, :tools_dir)
  end

  @doc """
  Sets the tools directory and rescans.

  Primarily intended for testing — allows reconfiguring the registry
  to use an isolated directory without restarting the GenServer.
  """
  @spec set_tools_dir(String.t()) :: non_neg_integer()
  def set_tools_dir(dir) do
    GenServer.call(__MODULE__, {:set_tools_dir, dir})
  end

  # ============================================================================
  # Server Callbacks
  # ============================================================================

  @impl true
  def init(opts) do
    tools_dir =
      Keyword.get(opts, :tools_dir) ||
        Application.get_env(:code_puppy_control, :uc_tools_dir) ||
        Paths.universal_constructor_dir()

    expanded_dir = Path.expand(tools_dir)

    state = %{
      tools_dir: expanded_dir,
      tools: %{},
      modules: %{},
      last_scan: nil
    }

    # Perform initial scan
    state = do_scan(state)

    {:ok, state}
  end

  @impl true
  def handle_call({:list_tools, opts}, _from, state) do
    include_disabled = Keyword.get(opts, :include_disabled, false)

    tools =
      state.tools
      |> Map.values()
      |> Enum.reject(fn t -> not include_disabled and not t.meta.enabled end)
      |> Enum.sort_by(& &1.full_name)

    {:reply, tools, state}
  end

  @impl true
  def handle_call({:get_tool, full_name}, _from, state) do
    tool = Map.get(state.tools, full_name)
    {:reply, tool, state}
  end

  @impl true
  def handle_call({:get_tool_function, full_name}, _from, state) do
    tool = Map.get(state.tools, full_name)

    result =
      if tool do
        module = Map.get(state.modules, full_name)
        func_name = find_main_function_name(module, tool.meta.name)

        if module && func_name do
          {module, func_name}
        else
          nil
        end
      else
        nil
      end

    {:reply, result, state}
  end

  @impl true
  def handle_call(:reload, _from, state) do
    new_state = do_scan(state)
    count = map_size(new_state.tools)
    {:reply, count, new_state}
  end

  @impl true
  def handle_call(:ensure_tools_dir, _from, state) do
    unless File.dir?(state.tools_dir) do
      Isolation.safe_mkdir_p!(state.tools_dir)
      Logger.info("Created UC tools directory: #{state.tools_dir}")
    end

    {:reply, state.tools_dir, state}
  end

  @impl true
  def handle_call(:tools_dir, _from, state) do
    {:reply, state.tools_dir, state}
  end

  @impl true
  def handle_call({:set_tools_dir, dir}, _from, state) do
    new_state = %{state | tools_dir: Path.expand(dir)}
    new_state = do_scan(new_state)
    count = map_size(new_state.tools)
    {:reply, count, new_state}
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp do_scan(state) do
    tools_dir = state.tools_dir

    if File.dir?(tools_dir) do
      tool_files = scan_tool_files(tools_dir)

      {tools, modules} =
        Enum.reduce(tool_files, {%{}, %{}}, fn file_path, {tools_acc, modules_acc} ->
          case load_tool_file(file_path, tools_dir) do
            {:ok, tool_info, module} ->
              {Map.put(tools_acc, tool_info.full_name, tool_info),
               Map.put(modules_acc, tool_info.full_name, module)}

            {:error, reason} ->
              Logger.warning("Failed to load UC tool from #{file_path}: #{reason}")
              {tools_acc, modules_acc}
          end
        end)

      %{state | tools: tools, modules: modules, last_scan: DateTime.utc_now()}
    else
      Logger.debug("UC tools directory does not exist: #{tools_dir}")
      %{state | tools: %{}, modules: %{}, last_scan: DateTime.utc_now()}
    end
  end

  defp scan_tool_files(tools_dir) do
    tools_dir
    |> Path.join("**/*.ex")
    |> Path.wildcard()
    |> Enum.reject(fn path ->
      basename = Path.basename(path)
      String.starts_with?(basename, "_") or String.starts_with?(basename, ".")
    end)
  end

  defp load_tool_file(file_path, tools_dir) do
    # Calculate namespace from relative path
    rel_path = Path.relative_to(file_path, tools_dir)
    namespace = extract_namespace(rel_path)

    # Try to compile and load the module
    try_load_module(file_path, namespace)
  end

  defp extract_namespace(rel_path) do
    parent = Path.dirname(rel_path)

    if parent == "." do
      ""
    else
      parent
      |> String.split("/")
      |> Enum.join(".")
    end
  end

  defp try_load_module(file_path, namespace) do
    # Read and extract @uc_tool attribute without full compilation
    case File.read(file_path) do
      {:ok, content} ->
        case extract_uc_tool_meta(content) do
          {:ok, meta} ->
            # Ensure namespace is set from directory structure
            meta = Map.put(meta, :namespace, namespace)

            # Build the tool info
            full_name = Models.full_name(meta.namespace, meta.name)

            # Try to compile the module
            case compile_and_load(file_path) do
              {:ok, module} ->
                func_name = find_main_function_name(module, meta.name)
                signature = build_signature(module, func_name)
                docstring = extract_docstring(module, func_name)

                tool_info =
                  Models.uc_tool_info(
                    meta: meta,
                    signature: signature,
                    source_path: file_path,
                    function_name: to_string(func_name),
                    docstring: docstring
                  )

                {:ok, tool_info, module}

              {:error, reason} ->
                # Still create tool info even if compilation fails
                tool_info =
                  Models.uc_tool_info(
                    meta: %{meta | enabled: false},
                    signature: "(compilation error)",
                    source_path: file_path,
                    function_name: meta.name,
                    docstring: nil
                  )

                Logger.warning("UC tool #{full_name} has compilation errors: #{reason}")
                {:ok, tool_info, nil}
            end

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, "Failed to read file: #{inspect(reason)}"}
    end
  end

  defp extract_uc_tool_meta(content) do
    # Look for @uc_tool attribute with a map
    pattern = ~r/@uc_tool\s+(%\{[^}]+\})/s

    case Regex.run(pattern, content) do
      [_, map_str] ->
        # Parse the map string safely
        parse_meta_map(map_str)

      nil ->
        # Try alternate format: @uc_tool %{...} with possible newlines
        alt_pattern = ~r/@uc_tool\s+(\%\{[\s\S]*?\n\s*\})/m

        case Regex.run(alt_pattern, content) do
          [_, map_str] ->
            parse_meta_map(map_str)

          nil ->
            {:error, "No @uc_tool attribute found"}
        end
    end
  end

  defp parse_meta_map(map_str) do
    # Delegate to Validator for safe literal parsing (security fix: no Code.eval_string)
    case Validator.safe_parse_literal_map(map_str) do
      {:ok, result} when is_map(result) ->
        meta =
          %{
            name: Map.get(result, :name, ""),
            namespace: Map.get(result, :namespace, ""),
            description: Map.get(result, :description, ""),
            enabled: Map.get(result, :enabled, true),
            version: Map.get(result, :version, "1.0.0"),
            author: Map.get(result, :author, ""),
            created_at: Map.get(result, :created_at)
          }

        if meta.name == "" do
          {:error, "Tool metadata missing required field: name"}
        else
          {:ok, meta}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp compile_and_load(file_path) do
    try do
      # Read the file
      {:ok, content} = File.read(file_path)

      # Create a temporary module name based on file path hash
      hash = :erlang.phash2(file_path, 1_000_000)
      module_name = Module.concat(["UCTool", "#{hash}"])

      # Compile the module
      case Code.compile_string(content, file_path) do
        [{^module_name, _} | _] ->
          {:ok, module_name}

        [{other_mod, _} | _] ->
          # Module defined its own name
          {:ok, other_mod}

        [] ->
          {:error, "No module defined in file"}
      end
    rescue
      e ->
        {:error, inspect(e)}
    end
  end

  # Known safe function-name atoms used as fallback candidates.
  # Only :run and :execute are ever atomized; user-controlled tool_name
  # is matched via String.to_existing_atom/1 (bounded) to avoid atom-table
  # exhaustion (code_puppy-mmk.2).
  @safe_fallback_atoms [:run, :execute]

  defp find_main_function_name(module, tool_name) when is_atom(module) do
    # Try String.to_existing_atom first — this only succeeds if the atom
    # already exists in the table (e.g. from compilation).  If the tool_name
    # has never been atomized, this raises and we skip to fallbacks.
    tool_atom =
      try do
        String.to_existing_atom(tool_name)
      rescue
        ArgumentError -> nil
      end

    candidates = if tool_atom, do: [tool_atom | @safe_fallback_atoms], else: @safe_fallback_atoms

    Enum.find_value(candidates, fn name ->
      if function_exported?(module, name, 1) do
        name
      else
        nil
      end
    end)
  end

  defp find_main_function_name(_, _), do: nil

  defp build_signature(module, func_name) when is_atom(module) and is_atom(func_name) do
    try do
      # Try to get function info from module's beam info
      info = module.__info__(:functions)

      arity =
        Enum.find_value(info, fn {name, ar} ->
          if name == func_name, do: ar, else: nil
        end) || 1

      "#{func_name}/#{arity}"
    rescue
      _ ->
        "#{func_name}/1"
    end
  end

  defp build_signature(_, _), do: "unknown/1"

  defp extract_docstring(module, func_name) when is_atom(module) and is_atom(func_name) do
    try do
      # Get @doc attribute if available
      case Code.fetch_docs(module) do
        {:docs_v1, _, _, _, _, _, docs} ->
          find_doc_for_function(docs, func_name)

        _ ->
          nil
      end
    rescue
      _ -> nil
    end
  end

  defp extract_docstring(_, _), do: nil

  defp find_doc_for_function(docs, func_name) do
    Enum.find_value(docs, fn
      {{:function, ^func_name, _}, _, _, doc, _} when is_binary(doc) ->
        doc

      _ ->
        nil
    end)
  end
end
