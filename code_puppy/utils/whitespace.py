"""Whitespace normalization helpers ported from plandex.

Prevents common LLM edit bugs where the model hallucinates extra
leading/trailing blank lines that weren't in the original file.
"""


def strip_added_blank_lines(orig: str, upd: str) -> str:
    """Remove leading/trailing blank lines that were added by the LLM.

    Compares original and updated text line-by-line. If `upd` has more
    leading blank lines than `orig`, trims the surplus. Same for trailing.
    Blank-line counts in the middle of the content are preserved.

    This mirrors plandex's server/utils/whitespace.go StripAddedBlankLines.

    Args:
        orig: The original file content (pre-edit).
        upd:  The updated file content (post-edit, from the LLM).

    Returns:
        `upd` with surplus leading/trailing blank lines stripped.
    """
    orig_lines = orig.split("\n")
    upd_lines = upd.split("\n")

    # Count leading blank lines in each
    leading_orig = 0
    while leading_orig < len(orig_lines) and orig_lines[leading_orig].strip() == "":
        leading_orig += 1
    leading_upd = 0
    while leading_upd < len(upd_lines) and upd_lines[leading_upd].strip() == "":
        leading_upd += 1
    if leading_upd > leading_orig:
        upd_lines = upd_lines[leading_upd - leading_orig :]

    # Count trailing blank lines in each
    trailing_orig = 0
    while (
        trailing_orig < len(orig_lines)
        and orig_lines[len(orig_lines) - 1 - trailing_orig].strip() == ""
    ):
        trailing_orig += 1
    trailing_upd = 0
    while (
        trailing_upd < len(upd_lines)
        and upd_lines[len(upd_lines) - 1 - trailing_upd].strip() == ""
    ):
        trailing_upd += 1
    if trailing_upd > trailing_orig:
        upd_lines = upd_lines[: len(upd_lines) - (trailing_upd - trailing_orig)]

    return "\n".join(upd_lines)
