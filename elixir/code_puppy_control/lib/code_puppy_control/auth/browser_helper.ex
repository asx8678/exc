defmodule CodePuppyControl.Auth.BrowserHelper do
  @moduledoc """
  Backward-compatible wrapper for the shared OAuth browser helper.

  New code should prefer `CodePuppyControl.Auth.Browser`, but this module
  remains as a stable alias while older call sites are migrated.
  """

  alias CodePuppyControl.Auth.Browser

  @spec suppress_browser?() :: boolean()
  def suppress_browser?, do: Browser.suppress_browser?()

  @spec open_url(String.t()) :: :ok
  def open_url(url) when is_binary(url) do
    _ = Browser.open_url(url)
    :ok
  end
end
