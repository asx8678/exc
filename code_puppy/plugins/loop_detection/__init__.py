"""Loop Detection Plugin for Code Puppy.

Detects and prevents agents from getting stuck in infinite loops making
identical tool calls. Hooks into pre_tool_call and post_tool_call callbacks
to track tool call patterns and intervene when repetition is detected.
"""
