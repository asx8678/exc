defmodule CodePuppyControlWeb.Admin.Components do
  @moduledoc """
  Shared HEEx components for the admin LiveView UI.

  Keep these primitives small. They are imported into every admin
  LiveView via `code_puppy_control_web.ex`'s `html_helpers/0` macro.
  Anything more complex than a simple visual atom belongs in its own
  LiveComponent.
  """

  use Phoenix.Component

  @doc """
  Sidebar navigation. `active` is one of the `:atom` keys in
  `nav_items/0` and gets the `.active` class.
  """
  attr :active, :atom, default: nil

  def sidebar(assigns) do
    ~H"""
    <nav class="admin-sidebar" aria-label="Admin navigation">
      <h2>CodePuppy Admin</h2>
      <ul>
        <li :for={item <- nav_items()}>
          <.link
            navigate={item.path}
            class={["nav-link", item.key == @active && "active"]}
          >
            {item.label}
          </.link>
        </li>
      </ul>
    </nav>
    """
  end

  @doc """
  Render a single status atom as a colored pill.
  """
  attr :status, :any, required: true
  attr :rest, :global

  def status_pill(assigns) do
    assigns = assign(assigns, :label, status_label(assigns.status))
    assigns = assign(assigns, :class, "pill status-#{status_label(assigns.status)}")

    ~H"""
    <span class={@class} {@rest}>{@label}</span>
    """
  end

  @doc """
  A single stat card (label, big value, optional subline).
  """
  attr :label, :string, required: true
  attr :value, :any, required: true
  attr :sub, :string, default: nil

  def stat_card(assigns) do
    ~H"""
    <div class="card">
      <div class="label">{@label}</div>
      <div class="value">{@value}</div>
      <div :if={@sub} class="sub">{@sub}</div>
    </div>
    """
  end

  @doc """
  Empty-state placeholder for tables/lists.
  """
  attr :message, :string, required: true

  def empty_state(assigns) do
    ~H"""
    <div class="empty">{@message}</div>
    """
  end

  @doc """
  Format a `DateTime` for display. `nil` → em-dash.
  """
  @spec format_dt(DateTime.t() | nil) :: String.t()
  def format_dt(nil), do: "—"

  def format_dt(%DateTime{} = dt) do
    dt
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  @doc """
  Format a duration in milliseconds as a human string.
  """
  @spec format_duration(non_neg_integer() | nil) :: String.t()
  def format_duration(nil), do: "—"
  def format_duration(ms) when ms < 1_000, do: "#{ms}ms"

  def format_duration(ms) when ms < 60_000 do
    seconds = Float.round(ms / 1_000, 1)
    "#{seconds}s"
  end

  def format_duration(ms) do
    minutes = div(ms, 60_000)
    seconds = div(rem(ms, 60_000), 1_000)
    "#{minutes}m #{seconds}s"
  end

  @doc """
  Truncate a string to `n` chars with an ellipsis suffix.
  """
  @spec truncate(any(), pos_integer()) :: String.t()
  def truncate(nil, _), do: ""

  def truncate(str, n) when is_binary(str) do
    if String.length(str) <= n do
      str
    else
      String.slice(str, 0, n - 1) <> "…"
    end
  end

  def truncate(other, n), do: other |> inspect() |> truncate(n)

  # ── Internals ─────────────────────────────────────────────────────────

  defp nav_items do
    [
      %{key: :dashboard, label: "Dashboard", path: "/admin"},
      %{key: :agents, label: "Agents", path: "/admin/agents"},
      %{key: :jobs, label: "Jobs", path: "/admin/jobs"},
      %{key: :worktrees, label: "Worktrees", path: "/admin/worktrees"},
      %{key: :pack, label: "Pack", path: "/admin/pack"}
    ]
  end

  defp status_label(status) when is_atom(status), do: Atom.to_string(status)
  defp status_label(status) when is_binary(status), do: status
  defp status_label(_), do: "unknown"
end
