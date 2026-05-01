defmodule CodePuppyControlWeb.ErrorView do
  @moduledoc """
  Minimal HTML/JSON error views for the admin LiveView UI.

  The API endpoints already render their own JSON errors via the
  per-controller error paths; this view exists so that the Phoenix
  endpoint's `render_errors` machinery can fall back to *something*
  when an exception escapes a LiveView mount or render. Without it,
  Phoenix's default fallback raises `(ArgumentError) no "500" html
  template defined for CodePuppyControlWeb.ErrorView`, which obscures
  the real cause of failures.
  """

  use Phoenix.Component

  @doc false
  def render("404.html", _assigns), do: "Not Found"
  def render("500.html", _assigns), do: "Internal Server Error"
  def render("404.json", _assigns), do: %{error: "not_found"}
  def render("500.json", _assigns), do: %{error: "internal_server_error"}

  def render(template, _assigns) do
    Phoenix.Controller.status_message_from_template(template)
  end
end
