"""Add model screen — browse and add models from the registry.

Replaces code_puppy/command_line/add_model_menu.py as a Textual Screen.

Two-step flow:
  Step 1: SearchableList of providers + provider info on the right
  Step 2: SearchableList of models for the selected provider + model details
"""

from textual.app import ComposeResult
from textual.binding import Binding
from textual.containers import Horizontal
from textual.widgets import Footer, RichLog, Static

from code_puppy.tui.base_screen import MenuScreen
from code_puppy.tui.widgets.searchable_list import SearchableList, SearchableListItem

# ---------------------------------------------------------------------------
# Module-level helpers (importable + testable without a running App)
# ---------------------------------------------------------------------------


async def _load_registry():
    """Load the ModelsDevRegistry asynchronously, returning None on failure."""
    try:
        from code_puppy.models_dev_parser import ModelsDevRegistry

        return await ModelsDevRegistry.create()
    except Exception:
        return None


def _add_model_to_config(model, provider) -> bool:
    """Add *model* from *provider* to the user's extra_models.json.

    Delegates to AddModelMenu._add_model_to_extra_config so all the
    existing logic (type-mapping, endpoint lookup, etc.) is reused.
    """
    try:
        from code_puppy.command_line.add_model_menu import AddModelMenu

        menu = AddModelMenu.__new__(AddModelMenu)  # skip full __init__
        # Provide the minimal state _add_model_to_extra_config needs
        menu.registry = None
        menu.providers = []
        menu.current_provider = None
        menu.current_models = []
        menu.view_mode = "models"
        menu.selected_provider_idx = 0
        menu.selected_model_idx = 0
        menu.current_page = 0
        menu.result = None
        menu.pending_model = None
        menu.pending_provider = None
        menu.is_custom_model_selected = False
        menu.custom_model_name = None
        return menu._add_model_to_extra_config(model, provider)
    except Exception as exc:
        try:
            from code_puppy.messaging import emit_error

            emit_error(f"Failed to add model: {exc}")
        except Exception:
            pass
        return False


def _format_provider_details(provider) -> str:
    """Return Rich-markup text describing a provider."""
    lines: list[str] = []
    lines.append(f"[bold cyan]{provider.name}[/bold cyan]")
    lines.append(f"[dim]ID:[/dim] {provider.id}")
    lines.append(f"[dim]Models:[/dim] {provider.model_count}")
    if provider.api:
        lines.append(f"[dim]API:[/dim] {provider.api}")
    if provider.env:
        env_str = ", ".join(provider.env)
        lines.append(f"[dim]Env vars:[/dim] {env_str}")
    if provider.doc:
        lines.append(f"[dim]Docs:[/dim] {provider.doc}")
    return "\n".join(lines)


def _format_model_details(model, provider) -> str:
    """Return Rich-markup text describing a model."""
    lines: list[str] = []
    lines.append(f"[bold cyan]{model.name}[/bold cyan]")
    lines.append(f"[dim]ID:[/dim] {model.model_id}")
    lines.append(f"[dim]Provider:[/dim] {provider.name}")

    if model.context_length:
        ctx_k = model.context_length // 1000
        lines.append(f"[dim]Context:[/dim] {ctx_k}k tokens")
    if model.max_output:
        out_k = model.max_output // 1000
        lines.append(f"[dim]Max output:[/dim] {out_k}k tokens")

    caps: list[str] = []
    if model.tool_call:
        caps.append("tools")
    if model.reasoning:
        caps.append("reasoning")
    if model.attachment:
        caps.append("attachments")
    if model.structured_output:
        caps.append("structured-output")
    if model.has_vision:
        caps.append("vision")
    if caps:
        lines.append(f"[dim]Capabilities:[/dim] {', '.join(caps)}")

    if model.cost_input is not None:
        lines.append(
            f"[dim]Cost:[/dim] ${model.cost_input:.4f}/1k in  "
            f"${model.cost_output:.4f}/1k out"
            if model.cost_output is not None
            else f"[dim]Cost in:[/dim] ${model.cost_input:.4f}/1k"
        )
    if model.knowledge:
        lines.append(f"[dim]Knowledge cutoff:[/dim] {model.knowledge}")

    lines.append("")
    lines.append("[dim]Press Enter to add this model.[/dim]")
    return "\n".join(lines)


# ---------------------------------------------------------------------------
# AddModelScreen
# ---------------------------------------------------------------------------

_TITLE_PROVIDERS = "📦  Add Model — Browse Providers  │  Enter=open  Esc=exit"
_TITLE_MODELS = "📦  Add Model — {provider}  │  Enter=add  Esc=back"


class AddModelScreen(MenuScreen):
    """Browse and add models from the models.dev registry.

    Step 1 — provider list:
        Left  : searchable list of all providers
        Right : provider details (env vars, docs, model count)

    Step 2 — model list:
        Left  : searchable list of models for the selected provider
        Right : model details (context, capabilities, cost)

    Bindings:
        Enter  — select provider / add model
        Escape — go back one step or exit
    """

    BINDINGS = MenuScreen.BINDINGS + [
        Binding("enter", "confirm_selection", "Select / Add", show=True),
    ]

    CSS = """
    AddModelScreen {
        layout: vertical;
        background: $surface;
    }

    #add-model-title {
        height: 1;
        background: $primary-darken-2;
        color: $text;
        text-style: bold;
        padding: 0 2;
    }

    #add-model-split {
        height: 1fr;
        layout: horizontal;
    }

    #add-model-list {
        width: 40%;
        min-width: 28;
        border-right: solid $primary-lighten-2;
    }

    #add-model-details {
        width: 1fr;
        padding: 1 2;
    }
    """

    def __init__(self) -> None:
        super().__init__()
        self._step: str = "providers"  # "providers" | "models"
        self._selected_provider = None
        self._registry = None

    # --- Compose & mount ---------------------------------------------------

    def compose(self) -> ComposeResult:
        yield Static(_TITLE_PROVIDERS, id="add-model-title")
        with Horizontal(id="add-model-split"):
            yield SearchableList(
                placeholder="🔍 Search providers…",
                id="add-model-list",
            )
            yield RichLog(
                id="add-model-details",
                highlight=True,
                markup=True,
                wrap=True,
            )
        yield Footer()

    async def on_mount(self) -> None:
        """Load registry and populate the provider list."""
        self._registry = await _load_registry()
        self._show_providers()

    # --- Step rendering ----------------------------------------------------

    def _show_providers(self) -> None:
        """Populate the list with all providers (Step 1)."""
        self._step = "providers"
        self._update_title(_TITLE_PROVIDERS)
        self._clear_details()

        item_list = self.query_one("#add-model-list", SearchableList)
        item_list.clear_items()

        if self._registry is None:
            self._write_details("[red]⚠ Failed to load models registry.[/red]\n")
            self._write_details(
                "[dim]Check your network connection and try again.[/dim]"
            )
            return

        providers = self._registry.get_providers()
        if not providers:
            self._write_details("[yellow]No providers found.[/yellow]")
            return

        items = [
            SearchableListItem(
                label=provider.name,
                item_id=provider.id,
                badge=f"{provider.model_count}",
            )
            for provider in providers
        ]
        item_list.add_items(items)
        self._write_details("[dim]Select a provider to browse its models.[/dim]")
        item_list.focus()

    def _show_models(self, provider_id: str) -> None:
        """Populate the list with models for a provider (Step 2)."""
        if not self._registry:
            return

        provider = self._registry.get_provider(provider_id)
        if not provider:
            return

        self._selected_provider = provider
        self._step = "models"
        title = _TITLE_MODELS.format(provider=provider.name)
        self._update_title(title)

        item_list = self.query_one("#add-model-list", SearchableList)
        item_list.clear_items()

        models = self._registry.get_models(provider_id)
        if not models:
            self._clear_details()
            self._write_details(
                f"[yellow]No models found for {provider.name}.[/yellow]"
            )
            return

        items = []
        for model in models:
            badge = f"{model.context_length // 1000}k" if model.context_length else ""
            items.append(
                SearchableListItem(
                    label=model.name,
                    item_id=model.model_id,
                    badge=badge,
                )
            )
        item_list.add_items(items)

        # Show provider-level info while nothing is highlighted yet
        self._clear_details()
        self._write_details(_format_provider_details(provider))
        item_list.focus()

    # --- Details panel helpers ---------------------------------------------

    def _update_title(self, text: str) -> None:
        try:
            self.query_one("#add-model-title", Static).update(text)
        except Exception:
            pass

    def _clear_details(self) -> None:
        try:
            self.query_one("#add-model-details", RichLog).clear()
        except Exception:
            pass

    def _write_details(self, text: str) -> None:
        try:
            self.query_one("#add-model-details", RichLog).write(text)
        except Exception:
            pass

    # --- Message handlers --------------------------------------------------

    def on_searchable_list_item_highlighted(
        self, event: SearchableList.ItemHighlighted
    ) -> None:
        """Update the details panel as the cursor moves."""
        if not self._registry:
            return

        item = event.item
        if self._step == "providers":
            provider = self._registry.get_provider(item.item_id)
            if provider:
                self._clear_details()
                self._write_details(_format_provider_details(provider))
        elif self._step == "models" and self._selected_provider:
            model = self._registry.get_model(self._selected_provider.id, item.item_id)
            if model:
                self._clear_details()
                self._write_details(
                    _format_model_details(model, self._selected_provider)
                )

    def on_searchable_list_item_selected(
        self, event: SearchableList.ItemSelected
    ) -> None:
        """Handle Enter on a list item."""
        self._handle_item_action(event.item.item_id)

    def action_confirm_selection(self) -> None:
        """Confirm the currently highlighted item."""
        item_list = self.query_one("#add-model-list", SearchableList)
        item = item_list.highlighted_item
        if item:
            self._handle_item_action(item.item_id)

    def _handle_item_action(self, item_id: str) -> None:
        """Dispatch enter-press depending on current step."""
        if self._step == "providers":
            self._show_models(item_id)
        elif self._step == "models":
            self._add_selected_model(item_id)

    def _add_selected_model(self, model_id: str) -> None:
        """Try to add the selected model to the user config."""
        if not self._registry or not self._selected_provider:
            return

        model = self._registry.get_model(self._selected_provider.id, model_id)
        if not model:
            self._clear_details()
            self._write_details(f"[red]Model '{model_id}' not found.[/red]")
            return

        success = _add_model_to_config(model, self._selected_provider)
        if success:
            self._clear_details()
            self._write_details(
                f"[bold green]✓ Added '{model.name}'![/bold green]\n\n"
                f"[dim]The model is now available in your model list.\n"
                f"Press Esc to close.[/dim]"
            )
        else:
            self._clear_details()
            self._write_details(
                f"[red]✗ Failed to add '{model.name}'.[/red]\n\n"
                f"[dim]Check logs for details. Press Esc to close.[/dim]"
            )

    # --- Navigation --------------------------------------------------------

    def action_pop_screen(self) -> None:
        """Go back one step, or pop screen if already at providers."""
        if self._step == "models":
            self._show_providers()
        else:
            super().action_pop_screen()
