"""Policy configuration loader for the PolicyEngine.

Loads policy rules from standard locations:
  - ~/.code_puppy/policy.json  (user-level, lower priority)
  - .code_puppy/policy.json    (project-level, higher priority)

Typical usage::

    from code_puppy.policy_config import load_policy_rules
    from code_puppy.policy_engine import PolicyEngine

    engine = PolicyEngine()
    load_policy_rules(engine)

Rules JSON format::

    {
      "rules": [
        {"tool_name": "read_file",       "decision": "allow",    "priority": 10},
        {"tool_name": "delete_file",     "decision": "deny",     "priority": 20},
        {"tool_name": "run_shell_command","command_pattern": "^git\\b", "decision": "allow", "priority": 15}
      ]
    }
"""

from pathlib import Path

from code_puppy.config_paths import resolve_path
from code_puppy.policy_engine import PolicyEngine


# Standard search paths (user then project; project rules win because
# they are loaded last and can have higher priority values).
# Respects pup-ex isolation (ADR-003) — user policy resolves under active home.
def _user_policy_path() -> Path:
    """Return the user policy path under the active home."""
    return resolve_path("policy.json")


_PROJECT_POLICY = Path.cwd() / ".code_puppy" / "policy.json"


def load_policy_rules(
    engine: PolicyEngine,
    *,
    user_policy: Path | None = None,
    project_policy: Path | None = None,
) -> int:
    """Load policy rules from user and project config files.

    Args:
        engine: The PolicyEngine instance to populate.
        user_policy: Override the user-level policy file path.
        project_policy: Override the project-level policy file path.

    Returns:
        Total number of rules loaded across all files.
    """
    user_path = user_policy if user_policy is not None else _user_policy_path()
    proj_path = project_policy if project_policy is not None else _PROJECT_POLICY

    total = 0
    total += engine.load_rules_from_file(user_path, source="user")
    total += engine.load_rules_from_file(proj_path, source="project")
    return total
