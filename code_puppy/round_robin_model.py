"""Round-robin model rotation - thin wrapper routing to Elixir.

Routes rotation state to Elixir when connected, uses local fallback when not.
This maintains interface compatibility (~40 lines core logic).
"""

from __future__ import annotations

import asyncio
import logging
from contextlib import asynccontextmanager, suppress
from typing import Any, AsyncIterator

from pydantic_ai._run_context import RunContext
from pydantic_ai.models import (
    Model,
    ModelMessage,
    ModelRequestParameters,
    ModelResponse,
    ModelSettings,
    StreamedResponse,
)

from code_puppy.plugins.elixir_bridge import call_elixir_round_robin, is_connected

logger = logging.getLogger(__name__)

# OpenTelemetry span handling (preserved from original)
try:
    from opentelemetry.context import get_current_span
except ImportError:

    def get_current_span():
        class DummySpan:
            def is_recording(self):
                return False

            def set_attributes(self, attributes):
                pass

        return DummySpan()


class RoundRobinModel(Model):
    """Routes model rotation to Elixir, keeps model delegation local."""

    def __init__(
        self,
        *models: Model,
        rotate_every: int = 1,
        settings: ModelSettings | None = None,
    ):
        super().__init__(settings=settings)
        if not models:
            raise ValueError("At least one model must be provided")
        if rotate_every < 1:
            raise ValueError("rotate_every must be at least 1")
        self.models = list(models)
        self._rotate_every = rotate_every
        self._current_index = 0  # For backward compatibility when Elixir unavailable
        self._request_count = 0
        self._lock = asyncio.Lock()
        if is_connected():
            self._configure_elixir()

    def _configure_elixir(self) -> None:
        """Configure Elixir with our model list (fire-and-forget)."""
        try:
            model_names = [m.model_name for m in self.models]
            asyncio.create_task(
                call_elixir_round_robin(
                    "round_robin.configure",
                    {"models": model_names, "rotate_every": self._rotate_every},
                )
            )
        except Exception:
            pass

    @property
    def model_name(self) -> str:
        names = ",".join(m.model_name for m in self.models)
        if self._rotate_every != 1:
            return f"round_robin:{names}:rotate_every={self._rotate_every}"
        return f"round_robin:{names}"

    @property
    def system(self) -> str:
        return self.models[self._current_index].system if self.models else ""

    @property
    def base_url(self) -> str | None:
        return self.models[self._current_index].base_url if self.models else None

    async def _get_next_model(self) -> Model:
        """Get next model (Elixir when connected, local fallback otherwise)."""
        if is_connected():
            result = await call_elixir_round_robin("round_robin.get_next", {})
            if result and result.get("model"):
                for i, m in enumerate(self.models):
                    if m.model_name == result["model"]:
                        self._current_index = i
                        return m
        # Local fallback rotation
        async with self._lock:
            model = self.models[self._current_index]
            self._request_count += 1
            if self._request_count >= self._rotate_every:
                self._current_index = (self._current_index + 1) % len(self.models)
                self._request_count = 0
            return model

    async def request(
        self,
        messages: list[ModelMessage],
        model_settings: ModelSettings | None,
        model_request_parameters: ModelRequestParameters,
    ) -> ModelResponse:
        from code_puppy.model_availability import availability_service

        current = await self._get_next_model()
        try:
            response = await current.request(
                messages, model_settings, model_request_parameters
            )
            availability_service.mark_healthy(current.model_name)
            self._set_span_attributes(current)
            return response
        except Exception as e:
            self._track_failure(current.model_name, e)
            raise

    @asynccontextmanager
    async def request_stream(
        self,
        messages: list[ModelMessage],
        model_settings: ModelSettings | None,
        model_request_parameters: ModelRequestParameters,
        run_context: RunContext[Any] | None = None,
    ) -> AsyncIterator[StreamedResponse]:
        current = await self._get_next_model()
        async with current.request_stream(
            messages, model_settings, model_request_parameters, run_context
        ) as resp:
            self._set_span_attributes(current)
            yield resp

    @staticmethod
    def _track_failure(model_name: str, error: Exception) -> None:
        """Track model failures (delegated to availability service)."""
        from code_puppy.model_availability import availability_service

        err_str = str(error).lower()
        status_code = getattr(error, "status_code", getattr(error, "status", None))

        if status_code == 429 or "quota" in err_str or "rate limit" in err_str:
            availability_service.mark_terminal(model_name, "quota")
        elif isinstance(status_code, int) and 500 <= status_code < 600:
            availability_service.mark_sticky_retry(model_name)
        elif "overloaded" in err_str or "capacity" in err_str:
            availability_service.mark_sticky_retry(model_name)

    def _set_span_attributes(self, model: Model) -> None:
        """Set span attributes for observability."""
        with suppress(Exception):
            span = get_current_span()
            if span.is_recording():
                attributes = getattr(span, "attributes", {})
                if attributes.get("gen_ai.request.model") == self.model_name:
                    span.set_attributes({"gen_ai.response.model": model.model_name})
