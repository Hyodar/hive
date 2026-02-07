# Ralph2

Autonomous AI agent loop that runs AI coding tools (Claude Code, Codex, Amp) repeatedly until all PRD items are complete. Each iteration is a fresh instance with clean context.

## Quick Start

```bash
# 1. Create a PRD interactively (launches AI tool to generate prd.json)
prd --tool claude       # or: codex, amp

# 2. Run the agent loop from your project directory (reads prd.json from CWD)
ralph2                          # defaults to claude
ralph2 --tool amp 5             # use amp, max 5 iterations
ralph2 --status                 # check progress
ralph2 --list                   # see all tasks
```

No per-project setup needed. Skills are installed globally by `hive worker setup`.

## Commands

| Command | Description |
|---------|-------------|
| `prd --tool <claude\|codex\|amp>` | Create a PRD and convert to `prd.json` interactively |
| `ralph2 [max_iterations]` | Run the agent loop (default: claude, 10 iterations) |
| `ralph2 --tool <name> [n]` | Run with a specific tool |
| `ralph2 --status` | Show PRD status summary |
| `ralph2 --next` | Show next pending task |
| `ralph2 --list` | List all tasks with status |
| `ralph2 --reset` | Reset all tasks to pending |
| `ralph2 --alert` | Enable Telegram alerts |
| `ralph2 --interactive` | Confirm before each iteration |

## Skills

Three global skills are installed for all AI tools during `hive worker setup`:

| Skill | Description |
|-------|-------------|
| `prd` | Generate Product Requirements Documents interactively |
| `ralph-tasks` | Convert PRDs to `prd.json` format for Ralph2 |
| `ralph` | Autonomous agent mode (implements stories from prd.json) |

Installed to:
- `~/.config/amp/skills/` (Amp)
- `~/.claude/skills/` (Claude Code)
- `~/.codex/skills/` (Codex)
- `/etc/hive/ralph2/skills/` (shared reference)

## Key Files

| File | Location | Description |
|------|----------|-------------|
| `prd.json` | Project CWD | PRD with user stories |
| `progress.txt` | Project CWD | Append-only progress log |
| `prd.json.example` | This directory | Template for manual PRD creation |
| `ralph2.sh` | This directory | The agent loop script |
| `prd` | This directory | PRD creation tool |
| `skills/prd/` | This directory | PRD generator skill |
| `skills/ralph/` | This directory | Autonomous agent skill |
| `skills/ralph-tasks/` | This directory | PRD-to-JSON converter skill |

## How It Works

1. `prd` launches an AI tool to create a PRD and convert it to `prd.json`
2. `ralph2` reads `prd.json` from the current directory
3. Each iteration sends a prompt referencing the global `ralph` skill at `/etc/hive/ralph2/skills/ralph/SKILL.md`
4. The AI tool reads the skill, picks the next pending story, implements it, and marks it done
5. Loop continues until all stories have `passes: true`

## Notifications

Ralph2 integrates with Telegram via `alertme` and `promptme`:

```bash
alertme --title "Title" --description "Details" --status success
RESPONSE=$(promptme --title "Question" --description "What should I do?" --timeout 300)
```
