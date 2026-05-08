defmodule CodePuppyControl.Plugins.AgentMemory.Signals do
  @moduledoc """
  Signal detection for user feedback patterns in conversation.

  Detects correction, reinforcement, and preference signals
  using compiled regex patterns on user messages.
  """

  @correction_delta -0.15
  @reinforcement_delta 0.10
  @preference_delta 0.05

  @type signal_type :: :correction | :reinforcement | :preference
  @type signal :: %{
          signal_type: signal_type(),
          confidence_delta: float(),
          matched_text: String.t(),
          context: map() | nil
        }

  @correction_patterns [
    ~r/\bactually[,;]?\s+(that"?s|is)\b/i,
    ~r/\bwait[,;]?\s+.*\b(wrong|incorrect|not right)\b/i,
    ~r/\bno[,;]?\s+(that|it|you|this)\b/i,
    ~r/\bnope[,;]?\s+(that|it|you|this)\b/i,
    ~r/\bthat"?s\s+(wrong|incorrect|not right)\b/i,
    ~r/\b(is|was)\s+(wrong|incorrect|not right)\b/i,
    ~r/\b(let me correct|correction:|to be accurate|to clarify)\b/i,
    ~r/\b(i|we)\s+(meant|mean|should have said|meant to say)\b/i,
    ~r/\bplease correct\b/i,
    ~r/\bi\s+(don"?t|do not)\s+(like|prefer|use|want)\b/i
  ]

  @reinforcement_patterns [
    ~r/\b(yes|yeah|yep|exactly|correct|right|precisely)[,.]?\s+(that|it|you|this)\b/i,
    ~r/\bthat"?s\s+(right|correct|true|accurate|good|perfect)\b/i,
    ~r/\bis\s+(right|correct|true|accurate|good|perfect)\b/i,
    ~r/\b(yes|yeah|yep|right|correct|exactly|absolutely|precisely)[!,.]?\s*$/i,
    ~r/\b(i agree|agreed|makes sense|good point|well said)\b/i,
    ~r/\b(perfect|excellent|great|awesome|nice)\b/i
  ]

  @preference_patterns [
    ~r/\b(i (really )?(prefer|like|love|enjoy|want|need))\b/i,
    ~r/\b(my preference is|my favorite|my preferred)\b/i,
    ~r/\b(i (don"?t|do not|never|always|usually)\s+(like|prefer|use|want|need))\b/i,
    ~r/\b(for me|in my case|personally)\s+(i |prefer|like|want|need)\b/i,
    ~r/\bi\s+(wish|hate|dislike)\b/i,
    ~r/\b(make sure to|remember to|always use)\b/i
  ]

  @doc "Check if text contains a correction signal."
  @spec has_correction?(String.t()) :: boolean()
  def has_correction?(text) do
    Enum.any?(@correction_patterns, &Regex.match?(&1, text))
  end

  @doc "Check if text contains a reinforcement signal."
  @spec has_reinforcement?(String.t()) :: boolean()
  def has_reinforcement?(text) do
    Enum.any?(@reinforcement_patterns, &Regex.match?(&1, text))
  end

  @doc "Check if text contains a preference signal."
  @spec has_preference?(String.t()) :: boolean()
  def has_preference?(text) do
    Enum.any?(@preference_patterns, &Regex.match?(&1, text))
  end

  @doc "Detect all memory signals in a text. Returns at most one per type."
  @spec detect_signals(String.t()) :: [signal()]
  def detect_signals(text) do
    []
    |> maybe_add_signal(:correction, @correction_delta, @correction_patterns, text)
    |> maybe_add_signal(:reinforcement, @reinforcement_delta, @reinforcement_patterns, text)
    |> maybe_add_signal(:preference, @preference_delta, @preference_patterns, text)
    |> Enum.reverse()
  end

  @doc "Apply signal confidence updates to existing facts for an agent."
  @spec apply_confidence_updates(String.t(), [map()], String.t() | nil) :: non_neg_integer()
  def apply_confidence_updates(agent_name, messages, _session_id) do
    alias CodePuppyControl.Plugins.AgentMemory.Storage

    user_msgs = Enum.filter(messages, &(&1["role"] in ~w(user human input)))
    facts = Storage.load(agent_name)

    if facts == [], do: 0, else: do_apply(user_msgs, facts, agent_name)
  end

  defp do_apply(user_msgs, facts, agent_name) do
    {count, updated} =
      Enum.reduce(user_msgs, {0, facts}, fn msg, {c, f} ->
        text = msg["content"] || ""
        if text == "", do: {c, f}, else: apply_to_text(text, f, c)
      end)

    if count > 0, do: CodePuppyControl.Plugins.AgentMemory.Storage.save(agent_name, updated)
    count
  end

  defp apply_to_text(text, facts, count) do
    signals = detect_signals(text)

    Enum.reduce(signals, {count, facts}, fn sig, {c, f} ->
      apply_signal(sig, f, c)
    end)
  end

  defp apply_signal(signal, facts, count) do
    Enum.reduce_while(facts, {count, facts}, fn fact, {c, all} ->
      ft = fact["text"] || ""

      if ft != "" and byte_size(ft) > 10 and has_word_overlap?(ft, signal.matched_text) do
        cur = Map.get(fact, "confidence", 0.5)
        new = (cur + signal.confidence_delta) |> max(0.0) |> min(1.0)

        if new != cur do
          upd =
            Enum.map(all, fn f ->
              if f["text"] == ft,
                do:
                  f
                  |> Map.put("confidence", new)
                  |> Map.put("last_reinforced", signal.matched_text),
                else: f
            end)

          {:halt, {c + 1, upd}}
        else
          {:cont, {c, all}}
        end
      else
        {:cont, {c, all}}
      end
    end)
  end

  defp has_word_overlap?(t1, t2) do
    w1 = extract_words(t1)
    w2 = extract_words(t2)

    if map_size(w1) == 0 or map_size(w2) == 0 do
      String.contains?(String.downcase(t1), String.downcase(t2)) or
        String.contains?(String.downcase(t2), String.downcase(t1))
    else
      MapSet.intersection(w1, w2) |> MapSet.size() >= 2 or
        String.contains?(String.downcase(t1), String.downcase(t2))
    end
  end

  defp extract_words(text) do
    ~r/[a-zA-Z0-9]{3,}/
    |> Regex.scan(String.downcase(text))
    |> List.flatten()
    |> MapSet.new()
  end

  defp maybe_add_signal(acc, type, delta, patterns, text) do
    case find_first_match(patterns, text) do
      nil ->
        acc

      match ->
        [%{signal_type: type, confidence_delta: delta, matched_text: match, context: nil} | acc]
    end
  end

  defp find_first_match(patterns, text) do
    Enum.find_value(patterns, fn pat ->
      case Regex.run(pat, text) do
        [m | _] -> m
        nil -> nil
      end
    end)
  end
end
