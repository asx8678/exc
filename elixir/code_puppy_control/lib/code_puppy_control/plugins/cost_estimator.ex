defmodule CodePuppyControl.Plugins.CostEstimator do
  @moduledoc """
  Token counting and cost estimation plugin.

  Provides `/cost` and `/estimate` slash commands for tracking session token
  usage and estimating costs for LLM API calls. Delegates token counting
  to `CodePuppyControl.Tokens.Estimator` and cost computation to
  `CodePuppyControl.TokenLedger.Cost`.

  ## Hooks Registered

    * `:custom_command` - handles `/cost` and `/estimate` slash commands
    * `:custom_command_help` - provides help entries for cost commands
    * `:pre_tool_call` - tracks token usage on tool calls
    * `:shutdown` - prints session cost summary on shutdown
  """

  use CodePuppyControl.Plugins.PluginBehaviour

  alias CodePuppyControl.Callbacks
  alias CodePuppyControl.TokenLedger.Cost
  alias CodePuppyControl.Tokens.Estimator

  require Logger

  @ets_table :cost_estimator_session_totals

  @impl true
  def name, do: "cost_estimator"

  @impl true
  def description, do: "Token counting and cost estimation for LLM API calls"

  @impl true
  def register do
    Callbacks.register(:custom_command, &__MODULE__.handle_command/2)
    Callbacks.register(:custom_command_help, &__MODULE__.command_help/0)
    Callbacks.register(:pre_tool_call, &__MODULE__.on_pre_tool_call/3)
    Callbacks.register(:shutdown, &__MODULE__.on_shutdown/0)
    :ok
  end

  @impl true
  def startup do
    ensure_ets_table()
    :ok
  end

  @impl true
  def shutdown do
    try do
      :ets.delete(@ets_table)
    rescue
      ArgumentError -> :ok
    end

    :ok
  end

  defp ensure_ets_table do
    case :ets.whereis(@ets_table) do
      :undefined ->
        :ets.new(@ets_table, [
          :set,
          :named_table,
          :public,
          read_concurrency: true,
          write_concurrency: true
        ])

      _ ->
        :ok
    end
  end

  @spec handle_command(String.t(), String.t()) :: String.t() | nil
  def handle_command(_command, "cost"), do: format_cost_summary()
  def handle_command(command, "estimate"), do: handle_estimate(command)
  def handle_command(_command, _name), do: nil

  defp format_cost_summary do
    ensure_ets_table()
    summary = get_session_summary()

    if summary.models == [] do
      "No token usage tracked in this session yet."
    else
      model_lines =
        Enum.map(summary.models, fn m ->
          "  - **#{m.model}**: #{format_number(m.total_tokens)} tokens (~$#{format_cost(m.estimated_cost_usd)})"
        end)

      lines =
        ["Session Cost Summary", ""] ++
          model_lines ++
          [
            "",
            "  **Total estimated cost**: $#{format_cost(summary.total_estimated_cost_usd)} USD"
          ]

      lines = lines ++ ["", "  _estimate - actual provider usage may differ_"]
      Enum.join(lines, "\n")
    end
  end

  defp handle_estimate(command) do
    parts = String.split(command, ~r/\s+/, parts: 2)

    text =
      case parts do
        [_, text] when byte_size(text) > 0 -> String.trim(text)
        _ -> nil
      end

    if text == nil do
      "Usage: /estimate <text or prompt to estimate>"
    else
      est = estimate_cost(text)

      result_lines = [
        "**Token Estimate**",
        "  - Input tokens: ~#{format_number(est.input_tokens)} (#{est.method})",
        "  - Expected output: ~#{format_number(est.output_tokens)} tokens",
        "  - Estimated cost: ~$#{format_cost(est.estimated_cost_usd)} USD",
        "  - Model: #{est.model}",
        "",
        "_estimate - actual provider usage may differ_"
      ]

      Enum.join(result_lines, "\n")
    end
  end

  @spec command_help() :: [{String.t(), String.t()}]
  def command_help do
    [
      {"/cost", "Show accumulated token usage and estimated costs for this session"},
      {"/estimate <text>", "Estimate token count and cost for given text"}
    ]
  end

  @spec on_pre_tool_call(String.t(), map(), term()) :: nil
  def on_pre_tool_call(tool_name, tool_args, _context) do
    if tool_name == "invoke_agent" do
      prompt = Map.get(tool_args, "prompt", "") || Map.get(tool_args, "message", "")

      if prompt != "" do
        model = Map.get(tool_args, "model", "gpt-4o")
        tokens = Estimator.estimate_tokens(to_string(prompt))
        track_session_tokens(model, tokens)

        if dry_run?() do
          Logger.info("cost_estimator: #{tool_name} ~#{tokens} tokens (#{model})")
        end
      end
    end

    nil
  end

  @spec on_shutdown() :: :ok
  def on_shutdown do
    ensure_ets_table()
    summary = get_session_summary()

    if summary.models != [] do
      Logger.info("Session cost estimate: ~$#{format_cost(summary.total_estimated_cost_usd)} USD")
    end

    :ok
  end

  @spec estimate_cost(String.t(), keyword()) :: map()
  def estimate_cost(prompt, opts \\ []) do
    model = Keyword.get(opts, :model, "gpt-4o")
    expected_output = Keyword.get(opts, :expected_output_tokens, 1024)
    {input_tokens, method} = {Estimator.estimate_tokens(prompt), "heuristic"}
    output_tokens = expected_output
    {input_cents, output_cents, _cached_cents} = Cost.cost_for_model(model)
    input_cost_usd = input_tokens * input_cents / 1_000_000_00
    output_cost_usd = output_tokens * output_cents / 1_000_000_00
    total_cost_usd = input_cost_usd + output_cost_usd

    %{
      input_tokens: input_tokens,
      output_tokens: output_tokens,
      model: model,
      estimated_cost_usd: total_cost_usd,
      method: method,
      provider_input_tokens: nil,
      provider_output_tokens: nil
    }
  end

  @spec track_session_tokens(String.t(), non_neg_integer()) :: :ok
  def track_session_tokens(model, tokens) do
    ensure_ets_table()
    :ets.update_counter(@ets_table, model, {2, tokens}, {model, 0})
    :ok
  end

  @spec get_session_summary() :: map()
  def get_session_summary do
    ensure_ets_table()

    totals =
      try do
        :ets.tab2list(@ets_table)
      rescue
        ArgumentError -> []
      end

    {total_cost, model_summaries} =
      Enum.reduce(totals, {0.0, []}, fn {model, token_count}, {cost_acc, summaries} ->
        {input_cents, _output_cents, _cached_cents} = Cost.cost_for_model(model)
        model_cost = token_count * input_cents / 1_000_000_00
        summary = %{model: model, total_tokens: token_count, estimated_cost_usd: model_cost}
        {cost_acc + model_cost, [summary | summaries]}
      end)

    %{models: Enum.reverse(model_summaries), total_estimated_cost_usd: total_cost}
  end

  @spec reset_session() :: :ok
  def reset_session do
    try do
      :ets.delete_all_objects(@ets_table)
    rescue
      ArgumentError -> :ok
    end

    :ok
  end

  defp dry_run? do
    System.get_env("PUP_DRY_RUN", "") in ["1", "true", "yes"]
  end

  defp format_number(n) when is_integer(n), do: format_number_int(n)
  defp format_number(n) when is_float(n), do: format_number(round(n))
  defp format_number_int(n) when n < 1_000, do: Integer.to_string(n)
  defp format_number_int(n), do: format_with_commas(n)

  defp format_with_commas(n) do
    n
    |> Integer.to_string()
    |> String.graphemes()
    |> Enum.reverse()
    |> Enum.chunk_every(3)
    |> Enum.join(",")
    |> String.reverse()
  end

  defp format_cost(usd) when is_float(usd), do: :erlang.float_to_binary(usd, decimals: 4)
  defp format_cost(usd) when is_integer(usd), do: format_cost(usd * 1.0)
end
