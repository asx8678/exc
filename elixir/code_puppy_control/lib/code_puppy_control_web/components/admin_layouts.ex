defmodule CodePuppyControlWeb.Admin.Layouts do
  @moduledoc """
  Layouts for the admin LiveView UI.

  Two layouts:

  * `root/1` — the outer HTML document (head, body, LiveView root).
    Wired via the router's `:put_root_layout` plug.
  * `app/1` — the in-page shell: sidebar, page header, content area.
    Wired via `use Phoenix.LiveView, layout: {__MODULE__, :app}` in
    `code_puppy_control_web.ex`.

  Styling is intentionally minimal — a single inline stylesheet shipped
  with `root/1` so the admin UI works without a separate asset
  pipeline. If/when we add Tailwind + an asset bundler, this stylesheet
  can be moved to `priv/static/admin.css`.
  """

  use Phoenix.Component

  import CodePuppyControlWeb.Admin.Components, only: [sidebar: 1]

  embed_templates "admin_layouts/*"
end
