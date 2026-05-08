"""Session Logger plugin - structured agent run archives.

Writes each agent run to a session directory with:
- main_agent.log: human-readable conversation transcript
- tool_calls.jsonl: machine-readable tool invocations
- manifest.json: session metadata (start/end time, duration, success)
"""

__version__ = "1.0.0"
