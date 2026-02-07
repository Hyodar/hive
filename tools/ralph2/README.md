# Ralph2

Autonomous AI agent loop that works through a PRD (Product Requirements Document) task by task. Supports Claude Code, Codex, and Amp.

## Commands

### `ralph2`

Run the agent loop or inspect task status.

```bash
ralph2                          # Run with Claude, 10 iterations
ralph2 --tool codex 5           # Run with Codex, 5 iterations
ralph2 --tool amp 20            # Run with Amp, 20 iterations
ralph2 --status                 # Show progress summary
ralph2 --list                   # List all tasks with status
ralph2 --next                   # Show next pending task
ralph2 --reset                  # Reset all tasks to pending
ralph2 --alert                  # Enable Telegram alerts
ralph2 --interactive            # Prompt before each iteration
```

| Option | Description |
|--------|-------------|
| `--tool <name>` | AI tool: `claude`, `codex`, `amp` (default: `claude`) |
| `--status` | Show PRD status summary and exit |
| `--next` | Show next pending task and exit |
| `--list` | List all tasks with status and exit |
| `--reset` | Reset all tasks to pending |
| `--alert` | Send Telegram alerts on completion/error |
| `--interactive` | Prompt for confirmation before each iteration |

### `ralphsetup`

Initialize ralph2 in a project directory.

```bash
ralphsetup .                        # Initialize in current directory
ralphsetup /path/to/project         # Initialize in specific directory
ralphsetup . --tool codex           # Set codex as default tool
ralphsetup --skills-only            # Only install global skills
```

| Option | Description |
|--------|-------------|
| `--force, -f` | Overwrite existing files |
| `--tool <name>` | Set default tool (`amp`, `claude`, `codex`) |
| `--skip-skills` | Don't install skills globally |
| `--skills-only` | Only install global skills, skip project setup |

## Files

| File | Purpose |
|------|---------|
| `prd.json` | Task definitions with priorities and acceptance criteria |
| `progress.txt` | Append-only log with learnings |
| `CLAUDE.md` | Agent instructions for Claude Code |
| `CODEX.md` | Agent instructions for Codex |
| `AGENTS.md` | Agent instructions for Amp |
| `prompt.md` | Amp-specific prompt file |
| `skills/prd/` | Skill for generating PRDs |
| `skills/ralph/` | Skill for converting PRDs to `prd.json` |

## Workflow

1. Run `ralphsetup .` in your project
2. Use the `/prd` skill with an AI agent to generate requirements
3. Use the `/ralph` skill to convert them to `prd.json`
4. Run `ralph2 --tool claude` to start the agent loop
5. Monitor with `ralph2 --status` or `--list`
