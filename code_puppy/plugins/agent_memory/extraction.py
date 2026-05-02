"""Fact extraction module for agent memory.

Uses LLM calls to extract structured facts from conversation messages.
Designed for async, non-blocking operation with proper error handling.
"""

import asyncio
import json
import logging
import re
from dataclasses import dataclass
from typing import Any, Protocol

logger = logging.getLogger(__name__)

# Default extraction prompt template
DEFAULT_EXTRACTION_PROMPT = """You are a fact extraction assistant. Your task is to extract important facts about the user from the conversation below.

Extract facts that would be useful to remember for future conversations, such as:
- User preferences (coding style, tools, formats)
- Technical details (frameworks, languages, versions)
- Context about the project (architecture, conventions)
- Personal work habits (communication style, workflow)

For each fact, provide:
1. The fact text (clear, concise statement)
2. Confidence level (0.0-1.0) based on how explicit/clear the information is

Return ONLY a JSON array in this exact format:
[
  {"text": "User prefers dark mode IDE", "confidence": 0.9},
  {"text": "Project uses React 18 with TypeScript", "confidence": 0.95}
]

If no extractable facts are found, return an empty array: []

Conversation:
{conversation}
"""


class LLMClient(Protocol):
    """Protocol for LLM clients that can be used for fact extraction."""

    async def complete(self, prompt: str) -> str:
        """Send a prompt to the LLM and return the response text."""
        ...


@dataclass(frozen=True, slots=True)
class ExtractedFact:
    """A fact extracted from conversation.

    Attributes:
        text: The fact statement
        confidence: Confidence level (0.0-1.0)
    """

    text: str
    confidence: float


class FactExtractor:
    """Extracts facts from conversation using LLM calls.

    This class handles the extraction workflow:
    1. Format conversation messages for extraction
    2. Call LLM with extraction prompt
    3. Parse and validate JSON response
    4. Return structured facts
    """

    def __init__(
        self,
        llm_client: LLMClient | None = None,
        prompt_template: str | None = None,
        min_confidence: float = 0.5,
    ) -> None:
        """Initialize the fact extractor.

        Args:
            llm_client: Optional LLM client for extraction. If None, uses
                       a simple mock that extracts basic patterns.
            prompt_template: Optional custom prompt template
            min_confidence: Minimum confidence threshold for extracted facts
        """
        self._llm_client = llm_client
        self._prompt_template = prompt_template or DEFAULT_EXTRACTION_PROMPT
        self._min_confidence = min_confidence

    def _format_conversation(self, messages: list[dict[str, Any]]) -> str:
        """Format conversation messages for the extraction prompt.

        Args:
            messages: List of message dicts with 'role' and 'content' keys

        Returns:
            Formatted conversation string
        """
        lines = []
        for msg in messages:
            role = msg.get("role", "unknown")
            content = msg.get("content", "")
            if content:
                lines.append(f"{role.upper()}: {content}")
        return "\n\n".join(lines)

    def _parse_response(self, response: str) -> list[ExtractedFact]:
        """Parse LLM response into ExtractedFact objects.

        Args:
            response: Raw LLM response text

        Returns:
            List of validated ExtractedFact objects
        """
        try:
            # Try to find JSON array in the response
            # Handle cases where LLM adds markdown or explanatory text
            response = response.strip()

            # Try to extract JSON array from markdown code blocks
            if "```json" in response:
                json_start = response.find("```json") + 7
                json_end = response.find("```", json_start)
                if json_end > json_start:
                    response = response[json_start:json_end].strip()
            elif "```" in response:
                json_start = response.find("```") + 3
                json_end = response.find("```", json_start)
                if json_end > json_start:
                    response = response[json_start:json_end].strip()

            # Parse the JSON
            data = json.loads(response)

            if not isinstance(data, list):
                logger.warning(f"Fact extraction returned non-list: {type(data)}")
                return []

            facts: list[ExtractedFact] = []
            for item in data:
                if not isinstance(item, dict):
                    continue

                text = item.get("text", "").strip()
                confidence = item.get("confidence", 0.0)

                # Validate and filter
                if not text or len(text) < 5:  # Skip very short facts
                    continue
                if confidence < self._min_confidence:
                    continue

                # Clamp confidence to valid range [0.0, 1.0]
                confidence = max(0.0, min(1.0, float(confidence)))

                # Create ExtractedFact using the constructor
                fact = ExtractedFact(text=text, confidence=confidence)
                facts.append(fact)

            return facts

        except json.JSONDecodeError as e:
            logger.warning(f"Failed to parse fact extraction response: {e}")
            return []
        except Exception as e:
            logger.error(f"Unexpected error parsing extraction response: {e}")
            return []

    async def extract_facts(
        self, messages: list[dict[str, Any]], timeout: float = 30.0
    ) -> list[ExtractedFact]:
        """Extract facts from conversation messages.

        Args:
            messages: List of message dicts with 'role' and 'content' keys
            timeout: Maximum time to wait for LLM response in seconds (default: 30)

        Returns:
            List of extracted facts meeting the confidence threshold
        """
        if not messages:
            return []

        # If no LLM client available, do basic pattern extraction
        if self._llm_client is None:
            return self._basic_extraction(messages)

        try:
            conversation = self._format_conversation(messages)
            prompt = self._prompt_template.format(conversation=conversation)

            # Wrap LLM call with timeout to prevent hanging
            response = await asyncio.wait_for(
                self._llm_client.complete(prompt), timeout=timeout
            )
            return self._parse_response(response)

        except Exception as e:
            logger.error(f"Fact extraction failed: {e}")
            return []

    def _basic_extraction(self, messages: list[dict[str, Any]]) -> list[ExtractedFact]:
        """Basic pattern-based extraction when no LLM available.

        This is a fallback that extracts simple preference statements
        using regex patterns.

        Args:
            messages: List of message dicts

        Returns:
            List of basic extracted facts
        """
        # Note: 're' is imported at module level

        facts: list[ExtractedFact] = []

        # Preference patterns for basic extraction
        preference_patterns = [
            (r"\bI\s+prefer\s+(.+?)[.!?,;]", 0.7),
            (r"\bI\s+like\s+(?:it\s+when\s+|to\s+)?(.+?)[.!?,;]", 0.6),
            (r"\bI\s+use\s+(.+?)(?:\s+for|\s+to|\.)", 0.8),
            (r"\bWe\s+use\s+(.+?)(?:\s+for|\s+to|\.)", 0.8),
            (r"\bMy\s+(.+?)\s+is\s+(.+?)[.!?]", 0.75),
        ]

        for msg in messages:
            content = msg.get("content", "")
            if not content or msg.get("role") != "user":
                continue

            for pattern, confidence in preference_patterns:
                matches = re.finditer(pattern, content, re.IGNORECASE)
                for match in matches:
                    # Extract the captured group or full match
                    if match.lastindex and match.lastindex > 0:
                        text = match.group(1).strip()
                        if match.lastindex > 1:
                            text = f"{match.group(1)}: {match.group(2)}"
                    else:
                        text = match.group(0).strip()

                    if len(text) > 10:  # Avoid very short matches
                        facts.append(ExtractedFact(text=text, confidence=confidence))

        # Deduplicate by text (keep highest confidence)
        seen: dict[str, float] = {}
        for fact in facts:
            if fact.text not in seen or seen[fact.text] < fact.confidence:
                seen[fact.text] = fact.confidence

        return [ExtractedFact(text=t, confidence=c) for t, c in seen.items()]


class MockLLMClient:
    """Mock LLM client for testing that returns predefined responses."""

    def __init__(self, response: str | None = None) -> None:
        """Initialize with optional fixed response.

        Args:
            response: Fixed response to return, or None for default empty array
        """
        self._response = response or "[]"
        self.calls: list[str] = []

    async def complete(self, prompt: str) -> str:
        """Record the call and return the mock response."""
        self.calls.append(prompt)
        return self._response
