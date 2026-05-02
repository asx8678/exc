# file_operations.py
# ---------------------------------------------------------------------------
# File operations - thin wrappers over Elixir transport
#
# Retired heavy Python implementations. Read operations now route
# through Elixir transport. Write/edit/delete operations remain in
# file_modifications.py until Elixir equivalents are built.
# ---------------------------------------------------------------------------
import os

from pydantic import BaseModel
from pydantic_ai import RunContext

from code_puppy.async_utils import format_size
from code_puppy.constants import MAX_READ_FILE_TOKENS
from code_puppy.messaging import FileContentMessage, get_message_bus
from code_puppy.sensitive_paths import is_sensitive_path
from code_puppy.token_counting import count_tokens
from code_puppy.utils.eol import normalize_eol, strip_bom
from code_puppy.utils.file_display import format_content_with_line_numbers
from code_puppy.utils.macos_path import resolve_path_with_variants


class ListedFile(BaseModel):
    path: str | None
    type: str | None
    size: int = 0
    full_path: str | None
    depth: int | None


class ListFileOutput(BaseModel):
    content: str
    error: str | None = None


class ReadFileOutput(BaseModel):
    content: str | None
    num_tokens: int
    error: str | None = None


class MatchInfo(BaseModel):
    file_path: str
    line_number: int
    line_content: str


class GrepOutput(BaseModel):
    matches: list[MatchInfo]
    error: str | None = None


def get_file_icon(file_path: str) -> str:
    ext = os.path.splitext(file_path)[1].lower()
    if ext in [".py", ".pyw"]:
        return "\U0001f40d"
    elif ext in [".js", ".jsx", ".ts", ".tsx"]:
        return "\U0001f4dc"
    elif ext in [".html", ".htm", ".xml"]:
        return "\U0001f310"
    elif ext in [".css", ".scss", ".sass"]:
        return "\U0001f3a8"
    elif ext in [".md", ".markdown", ".rst"]:
        return "\U0001f4dd"
    elif ext in [".json", ".yaml", ".yml", ".toml"]:
        return "\u2699\ufe0f"
    elif ext in [".jpg", ".jpeg", ".png", ".gif", ".svg", ".webp"]:
        return "\U0001f5bc\ufe0f"
    elif ext in [".mp3", ".wav", ".ogg", ".flac"]:
        return "\U0001f3b5"
    elif ext in [".mp4", ".avi", ".mov", ".webm"]:
        return "\U0001f3ac"
    elif ext in [".pdf", ".doc", ".docx", ".xls", ".xlsx", ".ppt", ".pptx"]:
        return "\U0001f4c4"
    elif ext in [".zip", ".tar", ".gz", ".rar", ".7z"]:
        return "\U0001f4e6"
    elif ext in [".exe", ".dll", ".so", ".dylib"]:
        return "\u26a1"
    else:
        return "\U0001f4c4"


def _is_sensitive_path(file_path: str) -> bool:
    return is_sensitive_path(file_path)


def validate_file_path(file_path: str, operation: str) -> tuple[bool, str | None]:
    if not file_path or not isinstance(file_path, str):
        return False, "File path cannot be empty"
    if "\x00" in file_path:
        return False, "File path contains null byte"
    if is_sensitive_path(file_path):
        return (
            False,
            f"Access to sensitive path blocked ({operation}): SSH keys, cloud credentials, and system secrets are never accessible.",
        )
    return True, None


def _read_file_sync(
    file_path: str, start_line: int | None = None, num_lines: int | None = None
) -> tuple[str | None, int, str | None]:
    """Synchronous file reading - kept as fallback for code_context."""
    file_path = os.path.abspath(os.path.expanduser(file_path))
    if not os.path.exists(file_path):
        file_path = resolve_path_with_variants(file_path)
    if not os.path.exists(file_path):
        return "", 0, f"File {file_path} does not exist"
    if not os.path.isfile(file_path):
        return "", 0, f"{file_path} is not a file"
    try:
        with open(file_path, "r", encoding="utf-8", errors="surrogateescape") as f:
            if start_line is not None and start_line < 1:
                return "", 0, "start_line must be >= 1 (1-based indexing)"
            if num_lines is not None and num_lines < 1:
                return "", 0, "num_lines must be >= 1"
            if start_line is not None and num_lines is not None:
                import itertools

                start_idx = start_line - 1
                selected_lines = list(
                    itertools.islice(f, start_idx, start_idx + num_lines)
                )
                content = "".join(selected_lines)
            else:
                content = f.read()
            content = content.encode("utf-8", errors="surrogatepass").decode(
                "utf-8", errors="replace"
            )
            content = normalize_eol(content)
            content, _ = strip_bom(content)
            num_tokens = count_tokens(content, model_name="gpt-4o")
            if num_tokens > MAX_READ_FILE_TOKENS:
                return (
                    None,
                    0,
                    f"The file is massive, greater than {MAX_READ_FILE_TOKENS:,} tokens which is dangerous to read entirely. Please read this file in chunks.",
                )
            total_lines = content.count("\n") + (
                1 if content and not content.endswith("\n") else 0
            )
            emit_start_line = (
                start_line if start_line is not None and start_line >= 1 else None
            )
            emit_num_lines = (
                num_lines if num_lines is not None and num_lines >= 1 else None
            )
            file_content_msg = FileContentMessage(
                path=file_path,
                content=content,
                start_line=emit_start_line,
                num_lines=emit_num_lines,
                total_lines=total_lines,
                num_tokens=num_tokens,
            )
            get_message_bus().emit(file_content_msg)
        return content, num_tokens, None
    except FileNotFoundError:
        return "", 0, "FILE NOT FOUND"
    except PermissionError:
        return "", 0, "PERMISSION DENIED"
    except Exception as e:
        message = f"An error occurred trying to read the file: {e}"
        return message, 0, message


def register_list_files(agent):
    """Register the list_files tool (routed through Elixir transport)."""
    from code_puppy.config import get_allow_recursion
    from code_puppy.elixir_transport_helpers import get_transport

    @agent.tool
    async def list_files(
        context: RunContext, directory: str = ".", recursive: bool = True
    ) -> ListFileOutput:
        """List files and directories with intelligent filtering and safety features."""
        warning = None
        if recursive and not get_allow_recursion():
            warning = "Recursion disabled globally for list_files - returning non-recursive results"
            recursive = False
        try:
            transport = get_transport()
            files = transport.list_files(directory, recursive=recursive)
            output_lines = [
                f"DIRECTORY LISTING: {os.path.abspath(directory)} (recursive={recursive})"
            ]
            for file_info in files:
                path = file_info.get("path", "")
                type_ = file_info.get("type", "file")
                size = file_info.get("size", 0)
                if type_ == "directory":
                    output_lines.append(f"📁 {path}/")
                else:
                    size_str = format_size(size) if size > 0 else "0 B"
                    icon = get_file_icon(path)
                    output_lines.append(f"{icon} {path} ({size_str})")
            content = "\n".join(output_lines)
            if warning:
                return ListFileOutput(content=content, error=warning)
            return ListFileOutput(content=content)
        except Exception as e:
            error_msg = f"Error listing files: {e}"
            return ListFileOutput(content=error_msg, error=error_msg)


def register_read_file(agent):
    """Register the read_file tool (routed through Elixir transport)."""
    from code_puppy.elixir_transport_helpers import get_transport
    from code_puppy.token_counting import count_tokens

    @agent.tool
    async def read_file(
        context: RunContext,
        file_path: str = "",
        start_line: int | None = None,
        num_lines: int | None = None,
        format_line_numbers: bool = False,
    ) -> ReadFileOutput:
        """Read file contents with optional line-range selection and token safety."""
        try:
            transport = get_transport()
            result = transport.read_file(file_path, start_line, num_lines)
            content = result.get("content", "")
            error = result.get("error")
            if format_line_numbers and content and not error:
                effective_start = start_line if start_line is not None else 1
                content = format_content_with_line_numbers(
                    content, start_line=effective_start
                )
            num_tokens = count_tokens(content) if content else 0
            return ReadFileOutput(content=content, num_tokens=num_tokens, error=error)
        except Exception as e:
            error_msg = f"Error reading file: {e}"
            return ReadFileOutput(content=None, num_tokens=0, error=error_msg)


def register_grep(agent):
    """Register the grep tool (routed through Elixir transport)."""
    from code_puppy.elixir_transport_helpers import get_transport

    @agent.tool
    async def grep(
        context: RunContext, search_string: str = "", directory: str = "."
    ) -> GrepOutput:
        """Recursively search for text patterns across files using ripgrep."""
        try:
            transport = get_transport()
            matches = transport.grep(search_string, directory)
            match_infos = [
                MatchInfo(
                    file_path=m.get("file", ""),
                    line_number=m.get("line_number", 0),
                    line_content=m.get("line_content", ""),
                )
                for m in matches
            ]
            return GrepOutput(matches=match_infos)
        except Exception as e:
            error_msg = f"Error during grep: {e}"
            return GrepOutput(matches=[], error=error_msg)
