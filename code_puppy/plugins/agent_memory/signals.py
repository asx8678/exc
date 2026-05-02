"""Signal detection module for agent memory.

Detects user feedback patterns in messages to adjust fact confidence:
- Corrections ("Actually, that's wrong...") → decrease confidence
- Reinforcements ("Yes, exactly!", "That's right") → increase confidence
- Preferences ("I prefer...", "I like...") → mark as preference

Supports English and Chinese language patterns.
"""

import re
from dataclasses import dataclass
from dataclasses import replace as dataclass_replace
from enum import Enum, auto
from typing import Any

# Confidence delta adjustments for each signal type
CORRECTION_DELTA = -0.3
REINFORCEMENT_DELTA = 0.1
PREFERENCE_DELTA = 0.15


class SignalType(Enum):
    """Types of memory signals that can be detected."""

    CORRECTION = auto()  # User correcting a previous statement
    REINFORCEMENT = auto()  # User confirming/agreeing
    PREFERENCE = auto()  # User stating a preference


@dataclass(frozen=True, slots=True)
class Signal:
    """A detected memory signal from user feedback.

    Attributes:
        signal_type: Type of signal detected
        confidence_delta: Amount to adjust fact confidence by
        matched_text: The text that matched the pattern
        context: Additional context about the signal
    """

    signal_type: SignalType
    confidence_delta: float
    matched_text: str
    context: dict[str, Any] | None = None


# Correction patterns - user indicating something is wrong
_CORRECTION_PATTERNS = [
    # English patterns
    r"\bactually[,;]?\s+(that'?s|is)\b",
    r"\bwait[,;]?\s+.*\b(wrong|incorrect|not right)\b",
    r"\bno[,;]?\s+(that|it|you|this)\b",
    r"\bnope[,;]?\s+(that|it|you|this)\b",
    r"\bthat'?s\s+(wrong|incorrect|not right)\b",
    r"\b(is|was)\s+(wrong|incorrect|not right)\b",
    r"\b(let me correct|correction:|to be accurate|to clarify)\b",
    r"\b(i|we)\s+(meant|mean|should have said|meant to say)\b",
    r"\b(that|it)\s+(should be|is actually|was actually)\s+\w+",
    r"\bplease correct\b",
    r"\bi\s+(don'?t|do not)\s+(like|prefer|use|want)\b",
    # Chinese patterns - 中文纠正模式
    r"不对",  # "not right"
    r"错了",  # "wrong"
    r"不正确",  # "incorrect"
    r"有误",  # "has error"
    r"纠正一下",  # "let me correct"
    r"更正",  # "correct/update"
    r"应该?是",  # "should be"
    r"其实",  # "actually"
    r"不[是对].*[你它这这]",  # "no, that's/it/you/this..."
    r"[你它这这].*错了",  # "you/it/this is wrong"
    r"不[是要对].*[是对好]",  # "this/it is not right/correct"
    r"不是正确",  # "not correct"
    r"不[要喜欢].*用",  # "don't like/use"
    r"我不是.*意思",  # "I didn't mean"
]

# Reinforcement patterns - user confirming/agreeing
_REINFORCEMENT_PATTERNS = [
    # English patterns
    r"\b(yes|yeah|yep|exactly|correct|right|precisely)[,.]?\s+(that|it|you|this)\b",
    r"\bthat'?s\s+(right|correct|true|accurate|good|perfect|exactly right)\b",
    r"\bis\s+(right|correct|true|accurate|good|perfect|exactly right)\b",
    r"\b(yes|yeah|yep|right|correct|exactly|absolutely|precisely)[!,.]?\s*$",
    r"\b(i agree|agreed|makes sense|good point|well said)\b",
    r"\b(thanks|thank you)\s+.*\b(right|correct|helpful|useful)\b",
    r"\b(perfect|excellent|great|awesome|nice)\b",
    # Chinese patterns - 中文确认模式
    r"对的",  # "that's right"
    r"没错",  # "correct/no mistake"
    r"正确",  # "correct"
    r"是[这样滴的]",  # "yes/that's right"
    r"[一]?点[儿]?都没错",  # "absolutely correct"
    r"完全正确",  # "completely correct"
    r"[很]?准确",  # "accurate"
    r"[正好]?说到点子[上]?",  # "well said"
    r"同意",  # "agree"
    r"说[得]?对",  # "said it right"
    r"你[说做讲提]?[得]?[对没错]",  # "you said/did right/correct"
    r"这样[很]?[对好]",  # "this is right/good"
]

# Preference patterns - user stating likes/dislikes
_PREFERENCE_PATTERNS = [
    # English patterns
    r"\b(i (really )?(prefer|like|love|enjoy|want|need))\b",
    r"\b(my preference is|my favorite|my preferred)\b",
    r"\b(i (don't|do not|never|always|usually|typically)\s+(like|prefer|use|want|need))\b",
    r"\b(for me|in my case|personally)\s+(i |prefer|like|want|need)\b",
    r"\bi\s+(wish|hate|dislike)\b",
    r"\b(make sure to|remember to|always use)\b",
    # Chinese patterns - 中文偏好模式
    r"我.*喜欢",  # "I like"
    r"我.*偏好",  # "I prefer"
    r"我.*[想需要][要]?",  # "I want/need"
    r"我[更]?喜欢",  # "I prefer/like more"
    r"[我的]?偏好是",  # "my preference is"
    r"[我的]?最爱是",  # "my favorite is"
    r"我.*不[想喜欢].*",  # "I don't like/want"
    r"我.*从来.*",  # "I never..."
    r"我.*通常.*",  # "I usually..."
    r"对我来说",  # "for me"
    r"我个人.*",  # "personally I..."
    r"我希望",  # "I wish"
    r"我讨厌",  # "I hate"
    r"我不喜欢",  # "I don't like"
    r"记得.*用",  # "remember to use"
    r"一定.*要",  # "make sure to"
    r"总是.*用",  # "always use"
]

# Pre-compile all patterns for performance
_COMPILED_CORRECTION = [re.compile(p, re.IGNORECASE) for p in _CORRECTION_PATTERNS]
_COMPILED_REINFORCEMENT = [
    re.compile(p, re.IGNORECASE) for p in _REINFORCEMENT_PATTERNS
]
_COMPILED_PREFERENCE = [re.compile(p, re.IGNORECASE) for p in _PREFERENCE_PATTERNS]


def has_correction(text: str) -> bool:
    """Check if text contains a correction signal.

    Args:
        text: The message text to check

    Returns:
        True if a correction pattern matches
    """
    return any(p.search(text) for p in _COMPILED_CORRECTION)


def has_reinforcement(text: str) -> bool:
    """Check if text contains a reinforcement signal.

    Args:
        text: The message text to check

    Returns:
        True if a reinforcement pattern matches
    """
    return any(p.search(text) for p in _COMPILED_REINFORCEMENT)


def has_preference(text: str) -> bool:
    """Check if text contains a preference signal.

    Args:
        text: The message text to check

    Returns:
        True if a preference pattern matches
    """
    return any(p.search(text) for p in _COMPILED_PREFERENCE)


def detect_signals(text: str) -> list[Signal]:
    """Detect all memory signals in a text.

    Scans the text for correction, reinforcement, and preference patterns.
    Returns all detected signals with their confidence deltas.

    Args:
        text: The message text to analyze

    Returns:
        List of detected Signal objects
    """
    signals: list[Signal] = []

    # Check for corrections
    for pattern in _COMPILED_CORRECTION:
        match = pattern.search(text)
        if match:
            signals.append(
                Signal(
                    signal_type=SignalType.CORRECTION,
                    confidence_delta=CORRECTION_DELTA,
                    matched_text=match.group(0),
                    context={"pattern": pattern.pattern},
                )
            )
            break  # Only count one correction per message

    # Check for reinforcements
    for pattern in _COMPILED_REINFORCEMENT:
        match = pattern.search(text)
        if match:
            signals.append(
                Signal(
                    signal_type=SignalType.REINFORCEMENT,
                    confidence_delta=REINFORCEMENT_DELTA,
                    matched_text=match.group(0),
                    context={"pattern": pattern.pattern},
                )
            )
            break  # Only count one reinforcement per message

    # Check for preferences
    for pattern in _COMPILED_PREFERENCE:
        match = pattern.search(text)
        if match:
            signals.append(
                Signal(
                    signal_type=SignalType.PREFERENCE,
                    confidence_delta=PREFERENCE_DELTA,
                    matched_text=match.group(0),
                    context={"pattern": pattern.pattern},
                )
            )
            break  # Only count one preference per message

    return signals


class SignalDetector:
    """Stateful signal detector for analyzing conversation history.

    This class maintains context across multiple messages and can
    correlate signals with specific facts that were mentioned.
    """

    def __init__(self) -> None:
        """Initialize the signal detector."""
        self._recent_facts: list[dict[str, Any]] = []
        self._max_history = 5

    def analyze_message(
        self, text: str, context_facts: list[dict[str, Any]] | None = None
    ) -> list[Signal]:
        """Analyze a message and detect signals.

        Args:
            text: The message text to analyze
            context_facts: Optional list of facts mentioned recently

        Returns:
            List of detected signals with context
        """
        if context_facts:
            self._recent_facts = context_facts[-self._max_history :]

        signals = detect_signals(text)

        # Enrich signals with recent fact context
        if signals and self._recent_facts:
            enriched_signals = []
            for signal in signals:
                # Use dataclasses.replace() for frozen dataclass mutation
                new_context = {**(signal.context or {})}
                new_context["recent_facts"] = [
                    f.get("text", "") for f in self._recent_facts
                ]
                enriched_signal = dataclass_replace(signal, context=new_context)
                enriched_signals.append(enriched_signal)
            signals = enriched_signals

        return signals

    def clear_history(self) -> None:
        """Clear the recent facts history."""
        self._recent_facts.clear()
