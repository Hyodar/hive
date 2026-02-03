# Ralph2 Agent Instructions

## Overview

Ralph2 is an enhanced autonomous AI agent loop that runs AI coding tools (Amp, Claude Code, or Codex) repeatedly until all PRD items are complete. Each iteration is a fresh instance with clean context.

## Commands

```bash
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

## Key Files

- `ralph2.sh` - The bash loop that spawns fresh AI instances (supports amp, claude, codex)
- `prompt.md` - Instructions given to each Amp instance
- `CLAUDE.md` - Instructions given to each Claude Code instance
- `CODEX.md` - Instructions given to each Codex instance
- `prd.json` - Product Requirements Document with user stories
- `progress.txt` - Append-only progress log with learnings

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

## Setup

Use `ralphsetup <directory>` to initialize ralph2 in a project:
- Copies prompt files and prd.json.example
- Creates initial progress.txt
- Sets up directory structure
