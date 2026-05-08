defmodule CodePuppyControl.HashlineNif do
  @moduledoc """
  Compatibility wrapper: delegates to pure Elixir `CodePuppyControl.HashLine`.
  uses the `xxhash` library for identical xxHash32 computation.

  This module is kept for API compatibility. New code should use
  `CodePuppyControl.HashLine` directly.
  """

  alias CodePuppyControl.HashLine

  defdelegate compute_line_hash(idx, line), to: HashLine
  defdelegate format_hashlines(text, start_line), to: HashLine
  defdelegate strip_hashline_prefixes(text), to: HashLine
  defdelegate validate_hashline_anchor(idx, line, expected_hash), to: HashLine
end
