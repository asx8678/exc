defmodule CodePuppyControl.Plugins.AgentMemory.Storage do
  @moduledoc """
  File-based storage for agent memory facts.

  Each agent has a JSON file at `~/.code_puppy_ex/memory/{agent_name}.json`
  containing a list of fact maps. All writes go through
  `Config.Isolation.safe_write!` to respect ADR-003.
  """

  alias CodePuppyControl.Config.{Isolation, Paths}

  @type fact :: map()

  @doc """
  Get the storage file path for an agent.
  """
  @spec file_path(String.t()) :: String.t()
  def file_path(agent_name) do
    Path.join(Paths.data_dir(), "memory/#{agent_name}.json")
  end

  @doc """
  Load all facts for an agent. Returns [] if file doesn't exist.
  """
  @spec load(String.t()) :: [fact()]
  def load(agent_name) do
    path = file_path(agent_name)

    case File.read(path) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, facts} when is_list(facts) -> facts
          _ -> []
        end

      {:error, _} ->
        []
    end
  end

  @doc """
  Save all facts for an agent (overwrites existing).
  """
  @spec save(String.t(), [fact()]) :: :ok | {:error, term()}
  def save(agent_name, facts) do
    path = file_path(agent_name)
    dir = Path.dirname(path)

    with :ok <- File.mkdir_p(dir),
         :ok <- Isolation.safe_write!(path, Jason.encode!(facts, pretty: true)) do
      :ok
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Add a single fact to storage.
  """
  @spec add_fact(String.t(), fact()) :: :ok
  def add_fact(agent_name, fact) do
    if is_map(fact) and Map.has_key?(fact, "text") do
      facts = load(agent_name)
      save(agent_name, facts ++ [fact])
    end

    :ok
  end

  @doc """
  Add multiple facts in a single batch.
  """
  @spec add_facts(String.t(), [fact()]) :: non_neg_integer()
  def add_facts(agent_name, facts) do
    valid = Enum.filter(facts, fn f -> is_map(f) and Map.has_key?(f, "text") end)

    if valid != [] do
      existing = load(agent_name)
      save(agent_name, existing ++ valid)
    end

    length(valid)
  end

  @doc """
  Remove a fact by its text. Returns true if found.
  """
  @spec remove_fact(String.t(), String.t()) :: boolean()
  def remove_fact(agent_name, text) do
    facts = load(agent_name)
    original_len = length(facts)
    filtered = Enum.reject(facts, fn f -> Map.get(f, "text") == text end)

    if length(filtered) < original_len do
      save(agent_name, filtered)
      true
    else
      false
    end
  end

  @doc """
  Clear all facts for an agent.
  """
  @spec clear(String.t()) :: :ok
  def clear(agent_name), do: save(agent_name, [])

  @doc """
  Get facts with optional confidence filtering.
  """
  @spec get_facts(String.t(), float()) :: [fact()]
  def get_facts(agent_name, min_confidence \\ 0.0) do
    facts = load(agent_name)

    if min_confidence <= 0.0 do
      facts
    else
      Enum.filter(facts, fn f ->
        Map.get(f, "confidence", 1.0) >= min_confidence
      end)
    end
  end

  @doc """
  Update fields of an existing fact identified by text.
  """
  @spec update_fact(String.t(), String.t(), map()) :: boolean()
  def update_fact(agent_name, text, updates) do
    facts = load(agent_name)

    found = Enum.any?(facts, fn f -> Map.get(f, "text") == text end)

    if found do
      updated =
        Enum.map(facts, fn f ->
          if Map.get(f, "text") == text, do: Map.merge(f, updates), else: f
        end)

      save(agent_name, updated)
      true
    else
      false
    end
  end

  @doc """
  Reinforce a fact by updating its last_reinforced timestamp.
  """
  @spec reinforce_fact(String.t(), String.t(), String.t() | nil) :: boolean()
  def reinforce_fact(agent_name, text, session_id \\ nil) do
    facts = load(agent_name)

    found = Enum.any?(facts, fn f -> Map.get(f, "text") == text end)

    if found do
      now = DateTime.utc_now() |> DateTime.to_iso8601()

      updated =
        Enum.map(facts, fn f ->
          if Map.get(f, "text") == text do
            f = Map.put(f, "last_reinforced", now)
            if session_id, do: Map.put(f, "source_session", session_id), else: f
          else
            f
          end
        end)

      save(agent_name, updated)
      true
    else
      false
    end
  end

  @doc """
  Return the number of stored facts.
  """
  @spec fact_count(String.t()) :: non_neg_integer()
  def fact_count(agent_name), do: length(load(agent_name))
end
