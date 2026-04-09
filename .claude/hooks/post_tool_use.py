#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.8"
# ///

import json
import os
import re
import sys
from pathlib import Path
from utils.constants import ensure_session_log_dir


def _get_bash_output(tool_response):
    """Extract text output from a Bash tool response."""
    if isinstance(tool_response, str):
        return tool_response
    if isinstance(tool_response, list):
        # List of content blocks — concatenate text blocks
        parts = []
        for block in tool_response:
            if isinstance(block, dict):
                parts.append(block.get("text", "") or block.get("output", "") or "")
            elif isinstance(block, str):
                parts.append(block)
        return "\n".join(p for p in parts if p)
    if isinstance(tool_response, dict):
        for key in ("output", "stdout", "content", "text"):
            val = tool_response.get(key)
            if isinstance(val, str) and val:
                return val
        return " ".join(str(v) for v in tool_response.values() if isinstance(v, str))
    return str(tool_response)


def _record_git_commits(session_id, command, tool_response, workspace_root):
    """If command ran a git commit, extract hash+message and append to session commits file."""
    if "git" not in command or "commit" not in command:
        return
    output = _get_bash_output(tool_response)
    # git commit output: [branch-name abc1234] commit message
    matches = re.findall(r"\[[\w./_-]+ ([0-9a-f]{7,40})\] (.+)", output)
    if not matches:
        return
    commits_dir = Path(workspace_root) / ".claude" / "planq-commits"
    commits_dir.mkdir(parents=True, exist_ok=True)
    commits_file = commits_dir / f"{session_id}.txt"
    with open(commits_file, "a") as f:
        for hash_, msg in matches:
            f.write(f"{hash_} {msg}\n")


def _append_commits_to_feedback(session_id, command, workspace_root):
    """If command is planq mark:done, append this session's commits to the feedback file."""
    # Match: planq mark:done X, planq mark done X, planq m:done X, planq m d X
    match = re.search(
        r"planq\s+(?:mark:done|mark\s+done|m:done|m\s+d)\s+((?:(?!&&|;|\||\n).)+)",
        command,
    )
    if not match:
        return

    commits_file = Path(workspace_root) / ".claude" / "planq-commits" / f"{session_id}.txt"
    if not commits_file.exists():
        return
    commits_content = commits_file.read_text().strip()
    if not commits_content:
        commits_file.unlink()
        return

    args_str = match.group(1).strip()
    # Parse identifiers, skipping --result/--notes flags and their values
    parts = args_str.split()
    identifiers = []
    skip_next = False
    for p in parts:
        if skip_next:
            skip_next = False
            continue
        if p in ("--result", "--notes"):
            skip_next = True
            continue
        identifiers.append(p.strip("\"'"))

    plans_dir = Path(workspace_root) / "plans"
    for ident in identifiers:
        # Skip purely numeric identifiers (position numbers — can't determine feedback file)
        if re.match(r"^\d+(\.\d+)*$", ident):
            continue
        # Determine feedback file path
        if ident.startswith("investigate-"):
            feedback_path = plans_dir / ident.replace("investigate-", "feedback-", 1)
        else:
            feedback_path = plans_dir / f"feedback-{ident}"
        if feedback_path.exists():
            existing = feedback_path.read_text()
            if "## Commits" not in existing:
                with open(feedback_path, "a") as f:
                    f.write(f"\n\n## Commits\n\n```\n{commits_content}\n```\n")
            break  # Only append once; all idents in a batch share the same session commits

    commits_file.unlink()


def main():
    try:
        # Read JSON input from stdin
        input_data = json.load(sys.stdin)

        # Extract fields
        session_id = input_data.get('session_id', 'unknown')
        tool_name = input_data.get('tool_name', '')
        tool_use_id = input_data.get('tool_use_id', '')
        tool_input = input_data.get('tool_input', {})
        tool_response = input_data.get('tool_response', {})
        is_mcp_tool = tool_name.startswith('mcp__')

        # Track git commits and append them to planq feedback on mark:done
        if tool_name == "Bash":
            command = tool_input.get("command", "")
            workspace_root = os.environ.get("CLAUDE_PROJECT_DIR", os.getcwd())
            _record_git_commits(session_id, command, tool_response, workspace_root)
            _append_commits_to_feedback(session_id, command, workspace_root)

        # Ensure session log directory exists
        log_dir = ensure_session_log_dir(session_id)
        log_path = log_dir / 'post_tool_use.json'

        # Read existing log data or initialize empty list
        if log_path.exists():
            with open(log_path, 'r') as f:
                try:
                    log_data = json.load(f)
                except (json.JSONDecodeError, ValueError):
                    log_data = []
        else:
            log_data = []

        # Build log entry with tool_use_id
        log_entry = {
            "tool_name": tool_name,
            "tool_use_id": tool_use_id,
            "session_id": session_id,
            "hook_event_name": input_data.get("hook_event_name", "PostToolUse"),
            "is_mcp_tool": is_mcp_tool,
        }

        # For MCP tools, log the server and tool parts
        if is_mcp_tool:
            parts = tool_name.split('__')
            if len(parts) >= 3:
                log_entry["mcp_server"] = parts[1]
                log_entry["mcp_tool_name"] = '__'.join(parts[2:])
            log_entry["input_keys"] = list(tool_input.keys())[:10]

        # Append log entry
        log_data.append(log_entry)

        # Write back to file with formatting
        with open(log_path, 'w') as f:
            json.dump(log_data, f, indent=2)

        sys.exit(0)

    except json.JSONDecodeError:
        # Handle JSON decode errors gracefully
        sys.exit(0)
    except Exception:
        # Exit cleanly on any other error
        sys.exit(0)

if __name__ == '__main__':
    main()
