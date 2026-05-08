defmodule CodePuppyControl.ModelPacks.ModelPack do
  @moduledoc """
  A model pack defining models for different roles.

  Fields:
  - `name` - Pack identifier
  - `description` - Human-readable description
  - `roles` - Mapping of role names to RoleConfig structs
  - `default_role` - Role to use when no specific role requested
  """

  alias CodePuppyControl.ModelPacks.RoleConfig

  defstruct [:name, :description, roles: %{}, default_role: "coder"]

  @type t :: %__MODULE__{
          name: String.t(),
          description: String.t(),
          roles: %{String.t() => RoleConfig.t()},
          default_role: String.t()
        }

  @doc """
  Get the primary model for a role.

  Returns the primary model name, or "auto" if role not found.

  ## Examples

      iex> pack = %ModelPack{
      ...>   roles: %{"coder" => %RoleConfig{primary: "claude-4"}},
      ...>   default_role: "coder"
      ...> }
      iex> ModelPack.get_model_for_role(pack, "coder")
      "claude-4"

      iex> ModelPack.get_model_for_role(pack, nil)
      "claude-4"
  """
  @spec get_model_for_role(t(), String.t() | nil) :: String.t()
  def get_model_for_role(%__MODULE__{} = pack, role) when is_binary(role) do
    case Map.get(pack.roles, role) do
      nil when role == pack.default_role ->
        # Default role not found - safe fallback
        "auto"

      nil ->
        get_model_for_role(pack, pack.default_role)

      %RoleConfig{primary: primary} ->
        primary
    end
  end

  def get_model_for_role(%__MODULE__{} = pack, nil) do
    get_model_for_role(pack, pack.default_role)
  end

  @doc """
  Get the full fallback chain for a role.

  Returns list of models: [primary, fallback1, fallback2, ...]

  ## Examples

      iex> pack = %ModelPack{
      ...>   roles: %{"coder" => %RoleConfig{primary: "a", fallbacks: ["b", "c"]}},
      ...>   default_role: "coder"
      ...> }
      iex> ModelPack.get_fallback_chain(pack, "coder")
      ["a", "b", "c"]
  """
  @spec get_fallback_chain(t(), String.t() | nil) :: [String.t()]
  def get_fallback_chain(%__MODULE__{} = pack, role) when is_binary(role) do
    case Map.get(pack.roles, role) do
      nil when role == pack.default_role ->
        ["auto"]

      nil ->
        get_fallback_chain(pack, pack.default_role)

      %RoleConfig{} = config ->
        RoleConfig.get_model_chain(config)
    end
  end

  def get_fallback_chain(%__MODULE__{} = pack, nil) do
    get_fallback_chain(pack, pack.default_role)
  end

  @doc """
  Convert the ModelPack to a plain map for JSON serialization.

  ## Examples

      iex> pack = %ModelPack{
      ...>   name: "test",
      ...>   description: "Test pack",
      ...>   roles: %{"coder" => %RoleConfig{primary: "gpt-4", fallbacks: ["gpt-3"]}},
      ...>   default_role: "coder"
      ...> }
      iex> ModelPack.to_map(pack)
      %{name: "test", description: "Test pack", default_role: "coder", roles: %{...}}
  """
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = pack) do
    roles_map =
      Map.new(pack.roles, fn {role_name, config} ->
        {role_name,
         %{
           primary: config.primary,
           fallbacks: config.fallbacks,
           trigger: config.trigger
         }}
      end)

    %{
      name: pack.name,
      description: pack.description,
      default_role: pack.default_role,
      roles: roles_map
    }
  end
end
