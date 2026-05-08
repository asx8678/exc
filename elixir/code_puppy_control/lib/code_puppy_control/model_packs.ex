defmodule CodePuppyControl.ModelPacks do
  @moduledoc """
  Model packs with role-based routing and fallback chains.

  Ports Python's code_puppy/model_packs.py.
  Each pack defines models for different task roles (planner, coder, reviewer)
  with fallback chains for provider failures or context overflow.

  ## Architecture

  Uses two ETS tables for storage:
  - `:model_packs` - Stores `{pack_name, %ModelPack{}}` tuples
  - `:model_packs_meta` - Stores metadata like `{:current_pack, pack_name}`

  Both tables are public with read concurrency for fast concurrent lookups.

  ## Default Packs

  Four built-in packs are created on initialization:
  - `"single"` - Uses one model (auto) for all tasks
  - `"coding"` - Coding-optimized with specialized models
  - `"economical"` - Cost-effective model selection
  - `"capacity"` - High-capacity models for large context windows

  ## User Packs

  User-defined packs are persisted to `~/.code_puppy/model_packs.json`.
  Built-in packs cannot be deleted.

  ## API

  - `start_link/1` - Start the GenServer
  - `get_pack/1` - Get pack by name (nil = current)
  - `list_packs/0` - List all packs (built-in + user)
  - `set_current_pack/1` - Set the active pack name
  - `get_current_pack/0` - Get the currently active pack
  - `get_model_for_role/1` - Get primary model for role in current pack
  - `get_fallback_chain/1` - Get full fallback chain for role
  - `create_pack/3` - Create a new user pack
  - `delete_pack/1` - Delete a user pack (built-ins protected)
  - `reload/0` - Reload user packs from JSON

  ## Examples

      iex> ModelPacks.get_pack("single")
      %ModelPacks.ModelPack{name: "single", ...}

      iex> ModelPacks.set_current_pack("coding")
      :ok

      iex> ModelPacks.get_model_for_role("coder")
      "wafer-glm-5.1"

      iex> ModelPacks.get_fallback_chain("coder")
      ["wafer-glm-5.1", "firepass-kimi-k2p5-turbo", "wafer-qwen3.5-397b"]
  """

  use GenServer

  require Logger

  alias CodePuppyControl.Config.Isolation
  alias CodePuppyControl.Config.Paths

  alias CodePuppyControl.ModelPacks.ModelPack
  alias CodePuppyControl.ModelPacks.RoleConfig

  @table :model_packs
  @meta_table :model_packs_meta
  @default_pack "single"

  # ============================================================================
  # Client API
  # ============================================================================

  @doc """
  Starts the ModelPacks GenServer.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Gets a model pack by name. Returns current pack if nil.
  Falls back to "single" pack if named pack doesn't exist.
  """
  @spec get_pack(String.t() | nil) :: ModelPack.t()
  def get_pack(name \\ nil) when is_binary(name) or is_nil(name) do
    name = name || get_current_pack_name()

    case :ets.lookup(@table, name) do
      [{^name, pack}] ->
        pack

      [] ->
        Logger.warning("Pack '#{name}' not found, using 'single'")
        [{"single", pack}] = :ets.lookup(@table, "single")
        pack
    end
  end

  @doc """
  Lists all available model packs.
  """
  @spec list_packs() :: [ModelPack.t()]
  def list_packs do
    @table
    |> :ets.tab2list()
    |> Enum.map(fn {_name, pack} -> pack end)
    |> Enum.sort_by(& &1.name)
  end

  @doc """
  Sets the current model pack. Returns `:ok` or `{:error, :not_found}`.
  """
  @spec set_current_pack(String.t()) :: :ok | {:error, :not_found}
  def set_current_pack(name) when is_binary(name) do
    GenServer.call(__MODULE__, {:set_current, name})
  end

  @doc """
  Gets the currently active model pack.
  """
  @spec get_current_pack() :: ModelPack.t()
  def get_current_pack do
    get_pack(get_current_pack_name())
  end

  @doc """
  Gets the primary model for a role using the current pack.
  """
  @spec get_model_for_role(String.t() | nil) :: String.t()
  def get_model_for_role(role \\ nil) do
    pack = get_current_pack()
    ModelPack.get_model_for_role(pack, role)
  end

  @doc """
  Gets the full fallback chain for a role using the current pack.
  """
  @spec get_fallback_chain(String.t() | nil) :: [String.t()]
  def get_fallback_chain(role \\ nil) do
    pack = get_current_pack()
    ModelPack.get_fallback_chain(pack, role)
  end

  @doc """
  Creates a new user-defined model pack. Cannot override built-in packs.
  """
  @spec create_pack(String.t(), String.t(), map(), String.t()) ::
          {:ok, ModelPack.t()} | {:error, :builtin_pack}
  def create_pack(name, description, roles_config, default_role \\ "coder")
      when is_binary(name) and is_binary(description) and is_map(roles_config) and
             is_binary(default_role) do
    GenServer.call(__MODULE__, {:create_pack, name, description, roles_config, default_role})
  end

  @doc """
  Deletes a user-defined model pack. Returns `true` if deleted.
  """
  @spec delete_pack(String.t()) :: boolean()
  def delete_pack(name) when is_binary(name) do
    GenServer.call(__MODULE__, {:delete_pack, name})
  end

  @doc """
  Reloads user-defined packs from `~/.code_puppy/model_packs.json`.
  """
  @spec reload() :: :ok
  def reload do
    GenServer.call(__MODULE__, :reload)
  end

  @doc """
  Checks if a pack is a built-in (default) pack.
  """
  @spec builtin_pack?(String.t()) :: boolean()
  def builtin_pack?(name) when is_binary(name) do
    name in ["single", "coding", "economical", "capacity"]
  end

  # ============================================================================
  # Private Helpers
  # ============================================================================

  defp get_current_pack_name do
    case :ets.lookup(@meta_table, :current_pack) do
      [{:current_pack, name}] -> name
      [] -> @default_pack
    end
  end

  # ============================================================================
  # Server Callbacks
  # ============================================================================

  @impl true
  def init(_opts) do
    # Create ETS tables for concurrent reads (write_concurrency not needed - single writer)
    table =
      :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])

    meta_table =
      :ets.new(@meta_table, [:named_table, :set, :public, read_concurrency: true])

    # Initialize default (built-in) packs
    default_packs = build_default_packs()

    for {name, pack} <- default_packs do
      :ets.insert(table, {name, pack})
    end

    # Load user-defined packs
    user_packs = load_user_packs_from_disk()

    for {name, pack} <- user_packs do
      :ets.insert(table, {name, pack})
    end

    # Set current pack (default to "single")
    :ets.insert(meta_table, {:current_pack, @default_pack})

    pack_count = map_size(default_packs) + map_size(user_packs)
    Logger.info("ModelPacks initialized with #{pack_count} packs")

    {:ok, %{table: table, meta_table: meta_table}}
  end

  @impl true
  def handle_call({:set_current, name}, _from, state) do
    case :ets.lookup(@table, name) do
      [{^name, _pack}] ->
        :ets.insert(state.meta_table, {:current_pack, name})
        Logger.info("Switched to model pack: #{name}")
        {:reply, :ok, state}

      [] ->
        available =
          @table
          |> :ets.select([{{:"$1", :_}, [], [:"$1"]}])
          |> Enum.join(", ")

        Logger.warning("Unknown model pack: #{name}. Available: #{available}")
        {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_call({:create_pack, name, description, roles_config, default_role}, _from, state) do
    if builtin_pack?(name) do
      Logger.error("Cannot override built-in pack: #{name}")
      {:reply, {:error, :builtin_pack}, state}
    else
      role_configs =
        Map.new(roles_config, fn {role_name, role_data} ->
          config = %RoleConfig{
            primary: Map.get(role_data, "primary") || Map.get(role_data, :primary, "auto"),
            fallbacks: Map.get(role_data, "fallbacks") || Map.get(role_data, :fallbacks, []),
            trigger:
              Map.get(role_data, "trigger") || Map.get(role_data, :trigger, "provider_failure")
          }

          {role_name, config}
        end)

      pack = %ModelPack{
        name: name,
        description: description,
        roles: role_configs,
        default_role: default_role
      }

      # Insert into ETS
      :ets.insert(state.table, {name, pack})

      # Persist to disk
      persist_user_packs(state.table)

      Logger.info("Created user pack: #{name}")
      {:reply, {:ok, pack}, state}
    end
  end

  @impl true
  def handle_call({:delete_pack, name}, _from, state) do
    cond do
      builtin_pack?(name) ->
        Logger.error("Cannot delete built-in pack: #{name}")
        {:reply, false, state}

      :ets.lookup(state.table, name) == [] ->
        Logger.error("Pack not found: #{name}")
        {:reply, false, state}

      true ->
        # Delete from ETS
        :ets.delete(state.table, name)

        # Check if we deleted the current pack
        current = get_current_pack_name()

        if current == name do
          :ets.insert(state.meta_table, {:current_pack, @default_pack})
          Logger.info("Reset to '#{@default_pack}' pack (previous pack was deleted)")
        end

        # Persist to disk
        persist_user_packs(state.table)

        Logger.info("Deleted user pack: #{name}")
        {:reply, true, state}
    end
  end

  @impl true
  def handle_call(:reload, _from, state) do
    # Remove all non-built-in packs
    all_packs = :ets.tab2list(state.table)

    for {name, _pack} <- all_packs do
      if not builtin_pack?(name) do
        :ets.delete(state.table, name)
      end
    end

    # Reload user packs from disk
    user_packs = load_user_packs_from_disk()

    for {name, pack} <- user_packs do
      :ets.insert(state.table, {name, pack})
    end

    # Verify current pack still exists
    current = get_current_pack_name()

    if :ets.lookup(state.table, current) == [] do
      :ets.insert(state.meta_table, {:current_pack, @default_pack})

      Logger.info(
        "Reset to '#{@default_pack}' pack after reload (previous pack no longer exists)"
      )
    end

    Logger.info("ModelPacks reloaded with #{map_size(user_packs)} user packs")
    {:reply, :ok, state}
  end

  @impl true
  def handle_info(msg, state) do
    Logger.warning("ModelPacks received unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  # ============================================================================
  # Private Functions - Default Packs
  # ============================================================================

  defp build_default_packs do
    %{
      "single" => build_single_pack(),
      "coding" => build_coding_pack(),
      "economical" => build_economical_pack(),
      "capacity" => build_capacity_pack()
    }
  end

  defp build_single_pack do
    %ModelPack{
      name: "single",
      description: "Use one model for all tasks",
      roles: %{
        "planner" => %RoleConfig{primary: "auto"},
        "coder" => %RoleConfig{primary: "auto"},
        "reviewer" => %RoleConfig{primary: "auto"},
        "summarizer" => %RoleConfig{primary: "auto"},
        "title" => %RoleConfig{primary: "auto"}
      },
      default_role: "coder"
    }
  end

  defp build_coding_pack do
    %ModelPack{
      name: "coding",
      description: "Optimized for coding tasks with specialized models",
      roles: %{
        "planner" => %RoleConfig{
          primary: "claude-sonnet-4",
          fallbacks: ["gpt-4o", "gemini-2.5-flash"],
          trigger: "context_overflow"
        },
        "coder" => %RoleConfig{
          primary: "wafer-glm-5.1",
          fallbacks: ["firepass-kimi-k2p5-turbo", "wafer-qwen3.5-397b"],
          trigger: "provider_failure"
        },
        "reviewer" => %RoleConfig{
          primary: "claude-sonnet-4",
          fallbacks: ["gpt-4o-mini"],
          trigger: "always"
        },
        "summarizer" => %RoleConfig{
          primary: "gemini-2.5-flash",
          fallbacks: ["gpt-4o-mini"],
          trigger: "context_overflow"
        },
        "title" => %RoleConfig{
          primary: "gpt-4o-mini",
          fallbacks: ["gemini-2.5-flash"],
          trigger: "always"
        }
      },
      default_role: "coder"
    }
  end

  defp build_economical_pack do
    %ModelPack{
      name: "economical",
      description: "Cost-effective model selection for budget-conscious usage",
      roles: %{
        "planner" => %RoleConfig{
          primary: "gemini-2.5-flash",
          fallbacks: ["gpt-4o-mini"],
          trigger: "context_overflow"
        },
        "coder" => %RoleConfig{
          primary: "firepass-kimi-k2p5-turbo",
          fallbacks: ["wafer-glm-5.1"],
          trigger: "provider_failure"
        },
        "reviewer" => %RoleConfig{
          primary: "gpt-4o-mini",
          fallbacks: ["gemini-2.5-flash"],
          trigger: "always"
        },
        "summarizer" => %RoleConfig{
          primary: "gemini-2.5-flash",
          fallbacks: ["gpt-4o-mini"],
          trigger: "always"
        },
        "title" => %RoleConfig{
          primary: "gpt-4o-mini",
          trigger: "always"
        }
      },
      default_role: "coder"
    }
  end

  defp build_capacity_pack do
    %ModelPack{
      name: "capacity",
      description: "Models with large context windows for big tasks",
      roles: %{
        "planner" => %RoleConfig{
          primary: "firepass-kimi-k2p5-turbo",
          fallbacks: ["wafer-qwen3.5-397b"],
          trigger: "context_overflow"
        },
        "coder" => %RoleConfig{
          primary: "wafer-qwen3.5-397b",
          fallbacks: ["firepass-kimi-k2p5-turbo"],
          trigger: "context_overflow"
        },
        "reviewer" => %RoleConfig{
          primary: "firepass-kimi-k2p5-turbo",
          fallbacks: ["claude-sonnet-4"],
          trigger: "context_overflow"
        },
        "summarizer" => %RoleConfig{
          primary: "wafer-qwen3.5-397b",
          fallbacks: ["firepass-kimi-k2p5-turbo"],
          trigger: "context_overflow"
        },
        "title" => %RoleConfig{
          primary: "gpt-4o-mini",
          trigger: "always"
        }
      },
      default_role: "coder"
    }
  end

  # ============================================================================
  # Private Functions - Persistence
  # ============================================================================

  defp load_user_packs_from_disk do
    packs_file = Paths.model_packs_file()

    case File.read(packs_file) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, data} when is_map(data) ->
            packs =
              Map.new(data, fn {pack_name, pack_data} ->
                roles =
                  Map.new(pack_data["roles"] || %{}, fn {role_name, role_config} ->
                    config = %RoleConfig{
                      primary: role_config["primary"] || "auto",
                      fallbacks: role_config["fallbacks"] || [],
                      trigger: role_config["trigger"] || "provider_failure"
                    }

                    {role_name, config}
                  end)

                pack = %ModelPack{
                  name: pack_name,
                  description: pack_data["description"] || "User-defined pack",
                  roles: roles,
                  default_role: pack_data["default_role"] || "coder"
                }

                {pack_name, pack}
              end)

            Logger.debug("ModelPacks: loaded #{map_size(packs)} user packs from #{packs_file}")
            packs

          _ ->
            Logger.warning("ModelPacks: failed to parse #{packs_file}")
            %{}
        end

      {:error, :enoent} ->
        # File doesn't exist - no user packs yet
        %{}

      {:error, reason} ->
        Logger.warning("ModelPacks: failed to read #{packs_file}: #{inspect(reason)}")
        %{}
    end
  end

  defp persist_user_packs(table) do
    packs_file = Paths.model_packs_file()

    # Get all non-built-in packs
    all_packs = :ets.tab2list(table)

    data =
      for {name, pack} <- all_packs,
          not builtin_pack?(name),
          into: %{} do
        roles_data =
          Map.new(pack.roles, fn {role_name, config} ->
            {role_name,
             %{
               "primary" => config.primary,
               "fallbacks" => config.fallbacks,
               "trigger" => config.trigger
             }}
          end)

        {name,
         %{
           "description" => pack.description,
           "default_role" => pack.default_role,
           "roles" => roles_data
         }}
      end

    # Ensure directory exists
    packs_file
    |> Path.dirname()
    |> Isolation.safe_mkdir_p!()

    # Write atomically (write to temp file then rename)
    temp_file = packs_file <> ".tmp"

    try do
      Isolation.safe_write!(temp_file, Jason.encode!(data, pretty: true))

      case File.rename(temp_file, packs_file) do
        :ok ->
          Logger.debug("ModelPacks: persisted user packs to #{packs_file}")

        {:error, reason} ->
          Logger.error("ModelPacks: rename failed (#{inspect(reason)}), data in #{temp_file}")
      end
    rescue
      e in File.Error ->
        Logger.error("ModelPacks: failed to persist user packs: #{Exception.message(e)}")
    end
  end
end
