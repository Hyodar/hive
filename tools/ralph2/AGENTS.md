# Ralph2 Agent Instructions

## Overview

Ralph2 is an enhanced autonomous AI agent loop that runs AI coding tools (Amp, Claude Code, or Codex) repeatedly until all PRD items are complete. Each iteration is a fresh instance with clean context.

## Quick Start

```bash
# 1. Create a PRD interactively (launches AI tool to generate prd.json)
prd --tool claude       # or: codex, amp

# 2. Run the agent loop from your project directory (reads prd.json from CWD)
ralph2                  # defaults to claude
ralph2 --tool amp 5     # use amp, max 5 iterations
```

## Commands

```bash
# Create a PRD and convert to prd.json
prd --tool claude       # or: codex, amp

# Show status summary
ralph2 --status

# Show next pending task
ralph2 --next

# List all tasks with status
ralph2 --list

# Run with Claude Code (default)
ralph2 [max_iterations]

# Run with specific tool
ralph2 --tool amp [max_iterations]
ralph2 --tool claude [max_iterations]
ralph2 --tool codex [max_iterations]

# Run with Telegram alerts
ralph2 --alert

# Interactive mode (confirm each iteration)
ralph2 --interactive
```

## Skills

Three global skills are installed for all AI tools during `hive worker setup`:

- **prd** - Generate Product Requirements Documents interactively
- **ralph-tasks** - Convert PRDs to `prd.json` format for Ralph2
- **ralph** - Autonomous agent mode (implements stories from prd.json)

Skills are installed to:
- `~/.config/amp/skills/` (Amp)
- `~/.claude/skills/` (Claude Code)
- `~/.codex/skills/` (Codex)
- `/etc/hive/ralph2/skills/` (shared reference)

## Key Files

- `prd.json` - Product Requirements Document with user stories (in project CWD)
- `progress.txt` - Append-only progress log with learnings (in project CWD)
- `/etc/hive/ralph2/ralph2.sh` - The bash loop that spawns fresh AI instances
- `/etc/hive/ralph2/skills/` - Global skill definitions

## Task Management with jq

Ralph2 uses jq extensively for task selection:

```bash
# Get next pending task
jq -r '.userStories | map(select(.passes == false)) | sort_by(.priority) | first' prd.json

# Count completed vs pending
jq '[.userStories[] | select(.passes == true)] | length' prd.json
jq '[.userStories[] | select(.passes == false)] | length' prd.json

# Mark task complete
jq '(.userStories[] | select(.id == "US-001")).passes = true' prd.json > tmp && mv tmp prd.json
```

## Notifications: alertme & promptme

Ralph2 integrates with Telegram for notifications. **Use these at the end of every task!**

### alertme - Send alerts
```bash
alertme --title "Title" --description "Details" --status success
alertme --title "Error" --description "What went wrong" --codeblock "error output" --status error
```

Status options: `success`, `info`, `warning`, `error`

### promptme - Get user input
```bash
RESPONSE=$(promptme --title "Question" --description "What should I do?" --timeout 300)
```

**Best practices:**
- Always `alertme` when a task completes
- Always `alertme` when an error occurs
- Use `promptme` sparingly - only when truly stuck
- Include relevant context in the description

## Patterns

- Each iteration spawns a fresh AI instance with clean context
- Memory persists via git history, `progress.txt`, and `prd.json`
- Stories should be small enough to complete in one context window
- Always update AGENTS.md/CLAUDE.md/CODEX.md with discovered patterns
- **Always notify via alertme at the end of each task**
- `prd.json` and `progress.txt` live in the project root (CWD), not in scripts/ralph/
- No per-project setup needed — skills are global, ralph2 reads from CWD
