defmodule CodePuppyControl.HookEngine.Registry do
  @moduledoc """
  Registry management for hooks.

  Builds and manages the HookRegistry from configuration maps.
  Supports **deduplicated registration** — registering a hook with the
  same ID twice is a no-op.

  Ported from `code_puppy/hook_engine/registry.py`.
  """

  require Logger

  alias CodePuppyControl.HookEngine.Models
  alias Models.{HookConfig, HookRegistry}

  @doc """
  Builds a `HookRegistry` from a configuration map.

  Deduplicates by hook ID — the first registration wins.

  ## Config Format

      %{
        "PreToolUse" => [
          %{
            "matcher" => "Bash",
            "hooks" => [
              %{"type" => "command", "command" => "./check.sh", "timeout" => 5000}
            ]
          }
        ]
      }
  """
  @spec build_from_config(map()) :: HookRegistry.t()
  def build_from_config(config) when is_map(config) do
    {entries, registered_ids} =
      Enum.reduce(config, {%{}, MapSet.new()}, fn {event_type, hook_groups}, {acc, ids} ->
        if to_string(event_type) |> String.starts_with?("_") do
          {acc, ids}
        else
          attr = Models.normalize_event_type(event_type)
          {hooks, new_ids} = parse_hook_groups(hook_groups, ids)
          {Map.put(acc, attr, hooks), new_ids}
        end
      end)

    %HookRegistry{entries: entries, executed_once: MapSet.new(), registered_ids: registered_ids}
  end

  @doc """
  Returns the list of enabled (non-once-executed) hooks for an event type.

  Filters out disabled hooks and already-executed `:once` hooks.
  """
  @spec get_hooks_for_event(HookRegistry.t(), String.t()) :: [HookConfig.t()]
  def get_hooks_for_event(%HookRegistry{} = registry, event_type) do
    attr = Models.normalize_event_type(event_type)
    hooks = Map.get(registry.entries, attr, [])

    Enum.filter(hooks, fn hook ->
      hook.enabled and not (hook.once and MapSet.member?(registry.executed_once, hook.id))
    end)
  end

  @doc """
  Marks a hook as executed (for `:once` hooks).

  Returns an updated registry.
  """
  @spec mark_hook_executed(HookRegistry.t(), String.t()) :: HookRegistry.t()
  def mark_hook_executed(%HookRegistry{} = registry, hook_id) do
    %{registry | executed_once: MapSet.put(registry.executed_once, hook_id)}
  end

  @doc """
  Resets all once-executed hooks (new session).
  """
  @spec reset_once_hooks(HookRegistry.t()) :: HookRegistry.t()
  def reset_once_hooks(%HookRegistry{} = registry) do
    %{registry | executed_once: MapSet.new()}
  end

  @doc """
  Adds a hook to the registry for the given event type.

  **Deduplicated** — if a hook with the same ID already exists, this is a no-op.
  Returns `{updated_registry, :ok}` or `{registry, :duplicate}`.
  """
  @spec add_hook(HookRegistry.t(), String.t(), HookConfig.t()) ::
          {HookRegistry.t(), :ok | :duplicate}
  def add_hook(%HookRegistry{} = registry, event_type, %HookConfig{} = hook) do
    if MapSet.member?(registry.registered_ids, hook.id) do
      Logger.debug("Hook '#{hook.id}' already registered, skipping (dedup)")
      {registry, :duplicate}
    else
      attr = Models.normalize_event_type(event_type)
      existing = Map.get(registry.entries, attr, [])
      new_ids = MapSet.put(registry.registered_ids, hook.id)

      {%{
         registry
         | entries: Map.put(registry.entries, attr, existing ++ [hook]),
           registered_ids: new_ids
       }, :ok}
    end
  end

  @doc """
  Removes a hook by ID from the given event type.

  Returns `{updated_registry, true}` if found and removed, or `{registry, false}` otherwise.
  """
  @spec remove_hook(HookRegistry.t(), String.t(), String.t()) ::
          {HookRegistry.t(), boolean()}
  def remove_hook(%HookRegistry{} = registry, event_type, hook_id) do
    attr = Models.normalize_event_type(event_type)

    case Map.get(registry.entries, attr) do
      nil ->
        {registry, false}

      hooks ->
        before_count = length(hooks)
        filtered = Enum.reject(hooks, &(&1.id == hook_id))
        after_count = length(filtered)

        if before_count == after_count do
          {registry, false}
        else
          new_ids = MapSet.delete(registry.registered_ids, hook_id)

          updated = %{
            registry
            | entries: Map.put(registry.entries, attr, filtered),
              registered_ids: new_ids
          }

          {updated, true}
        end
    end
  end

  @doc """
  Counts hooks in the registry.

  If `event_type` is nil, counts all hooks across all event types.
  """
  @spec count_hooks(HookRegistry.t(), String.t() | nil) :: non_neg_integer()
  def count_hooks(registry, event_type \\ nil)

  def count_hooks(%HookRegistry{} = registry, nil) do
    registry.entries
    |> Map.values()
    |> Enum.reduce(0, fn hooks, acc -> acc + length(hooks) end)
  end

  def count_hooks(%HookRegistry{} = registry, event_type) do
    attr = Models.normalize_event_type(event_type)
    registry.entries |> Map.get(attr, []) |> length()
  end

  @doc """
  Returns statistics about the registry.
  """
  @spec get_stats(HookRegistry.t()) :: map()
  def get_stats(%HookRegistry{} = registry) do
    stats = %{total_hooks: 0, enabled_hooks: 0, disabled_hooks: 0, by_event: %{}}

    Enum.reduce(registry.entries, stats, fn {attr, hooks}, acc ->
      enabled = Enum.count(hooks, & &1.enabled)
      disabled = length(hooks) - enabled

      # Reverse-lookup the original CamelCase event type name
      reverse_attr =
        Models.supported_event_types()
        |> Enum.find("Unknown", fn et ->
          Models.normalize_event_type(et) == attr
        end)

      acc
      |> Map.update!(:total_hooks, &(&1 + length(hooks)))
      |> Map.update!(:enabled_hooks, &(&1 + enabled))
      |> Map.update!(:disabled_hooks, &(&1 + disabled))
      |> put_in([:by_event, reverse_attr], %{
        total: length(hooks),
        enabled: enabled,
        disabled: disabled
      })
    end)
  end

  # ── Private ─────────────────────────────────────────────────────

  @spec parse_hook_groups(term(), MapSet.t(String.t())) ::
          {[HookConfig.t()], MapSet.t(String.t())}
  defp parse_hook_groups(hook_groups, ids) when is_list(hook_groups) do
    Enum.reduce(hook_groups, {[], ids}, fn group, {hooks_acc, ids_acc} ->
      {new_hooks, new_ids} = parse_group(group, ids_acc)
      {hooks_acc ++ new_hooks, new_ids}
    end)
  end

  defp parse_hook_groups(_hook_groups, ids), do: {[], ids}

  @spec parse_group(term(), MapSet.t(String.t())) :: {[HookConfig.t()], MapSet.t(String.t())}
  defp parse_group(%{} = group, ids) do
    matcher = Map.get(group, "matcher", "*")
    hooks_data = Map.get(group, "hooks", [])

    hooks_data
    |> List.wrap()
    |> Enum.reduce({[], ids}, fn
      %{} = hook_data, {hooks_acc, ids_acc} ->
        {hook, new_ids} = parse_hook(hook_data, matcher, ids_acc)
        {hooks_acc ++ List.wrap(hook), new_ids}

      _, acc ->
        acc
    end)
  end

  defp parse_group(_group, ids), do: {[], ids}

  @spec parse_hook(map(), String.t(), MapSet.t(String.t())) ::
          {HookConfig.t() | nil, MapSet.t(String.t())}
  defp parse_hook(hook_data, matcher, ids) do
    hook_type_str = Map.get(hook_data, "type", "command")
    command = Map.get(hook_data, "command") || Map.get(hook_data, "prompt", "")

    hook_type =
      case to_string(hook_type_str) do
        "prompt" -> :prompt
        _ -> :command
      end

    if hook_type == :command and (is_nil(command) or command == "") do
      {nil, ids}
    else
      try do
        hook =
          HookConfig.new(
            matcher: matcher,
            type: hook_type,
            command: command || "",
            timeout: Map.get(hook_data, "timeout", 5000),
            once: Map.get(hook_data, "once", false),
            enabled: Map.get(hook_data, "enabled", true),
            id: Map.get(hook_data, "id")
          )

        # Dedup: skip if ID already registered
        if MapSet.member?(ids, hook.id) do
          Logger.debug(
            "Hook '#{hook.id}' already registered during config build, skipping (dedup)"
          )

          {nil, ids}
        else
          {hook, MapSet.put(ids, hook.id)}
        end
      rescue
        e in ArgumentError ->
          Logger.warning("Skipping invalid hook: #{Exception.message(e)}")
          {nil, ids}
      end
    end
  end
end
