# Ralph2 Agent Instructions (Codex)

You are an autonomous coding agent working on a software project using OpenAI Codex.

## Your Task

1. Read the PRD at `prd.json` (in the same directory as this file)
2. Read the progress log at `progress.txt` (check Codebase Patterns section first)
3. Check you're on the correct branch from PRD `branchName`. If not, check it out or create from main.
4. Pick the **highest priority** user story where `passes: false`
5. **Signal task start:** `signalme --id task_started --content "[Story ID]"`
6. Implement that single user story
7. **Signal implementation done:** `signalme --id task_executed --content "[Story ID]"`
8. Run quality checks (e.g., typecheck, lint, test - use whatever your project requires)
9. Update CODEX.md files if you discover reusable patterns (see below)
10. If checks pass, commit ALL changes with message: `feat: [Story ID] - [Story Title]`
11. Update the PRD to set `passes: true` for the completed story
12. Append your progress to `progress.txt`
13. **Send completion alert using `alertme`** (see Notifications section)
14. **Signal task finished:** `signalme --id task_finished --content "[Story ID]"`

## Task Selection with jq

Use these commands to inspect and select tasks:

```bash
# Get next pending task (highest priority, passes=false)
jq -r '.userStories | map(select(.passes == false)) | sort_by(.priority) | first' prd.json

# Count pending tasks
jq '[.userStories[] | select(.passes == false)] | length' prd.json

# List all tasks with status
jq -r '.userStories[] | "\(if .passes then "DONE" else "TODO" end) [\(.priority)] \(.id): \(.title)"' prd.json

# Mark task as complete (replace TASK_ID with actual ID)
jq '(.userStories[] | select(.id == "TASK_ID")).passes = true' prd.json > prd.json.tmp && mv prd.json.tmp prd.json

# Get task details
jq '.userStories[] | select(.id == "US-001")' prd.json

# Check if all tasks complete
jq 'all(.userStories[]; .passes == true)' prd.json
```

## Progress Report Format

APPEND to progress.txt (never replace, always append):
```
## [Date/Time] - [Story ID]
- What was implemented
- Files changed
- **Learnings for future iterations:**
  - Patterns discovered (e.g., "this codebase uses X for Y")
  - Gotchas encountered (e.g., "don't forget to update Z when changing W")
  - Useful context (e.g., "the evaluation panel is in component X")
---
```

The learnings section is critical - it helps future iterations avoid repeating mistakes and understand the codebase better.

## Consolidate Patterns

If you discover a **reusable pattern** that future iterations should know, add it to the `## Codebase Patterns` section at the TOP of progress.txt (create it if it doesn't exist):

```
## Codebase Patterns
- Example: Use `sql<number>` template for aggregations
- Example: Always use `IF NOT EXISTS` for migrations
- Example: Export types from actions.ts for UI components
```

Only add patterns that are **general and reusable**, not story-specific details.

## Update CODEX.md Files

Before committing, check if any edited files have learnings worth preserving in nearby CODEX.md files:

1. **Identify directories with edited files** - Look at which directories you modified
2. **Check for existing CODEX.md** - Look for CODEX.md in those directories or parent directories
3. **Add valuable learnings** - If you discovered something future developers/agents should know:
   - API patterns or conventions specific to that module
   - Gotchas or non-obvious requirements
   - Dependencies between files
   - Testing approaches for that area

**Do NOT add:**
- Story-specific implementation details
- Temporary debugging notes
- Information already in progress.txt

## Quality Requirements

- ALL commits must pass your project's quality checks (typecheck, lint, test)
- Do NOT commit broken code
- Keep changes focused and minimal
- Follow existing code patterns
- Prefer small, incremental changes over large refactors

## Notifications (alertme & promptme)

**IMPORTANT:** Use `alertme` at the end of each task to notify the user of progress.

### alertme - Send notifications
```bash
# On task completion
alertme --title "Task Complete" --description "US-001: Add priority field" --status success

# On warning/issue
alertme --title "Task Complete with Warnings" --description "US-002 done but tests are slow" --status warning

# On error
alertme --title "Task Failed" --description "Build errors in component X" --codeblock "$(cat error.log)" --status error

# Status options: success, info, warning, error
```

### promptme - Get user input (when truly needed)
```bash
# Ask a question and wait for response (max 5 minutes)
ANSWER=$(promptme --title "Clarification Needed" --description "Should I use approach A or B?" --timeout 300)
echo "User said: $ANSWER"

# Ask with code context
ANSWER=$(promptme --title "Review Required" --description "Is this implementation correct?" --codeblock "$(cat file.ts)" --timeout 600)
```

**Always send an alert when:**
- A task is completed successfully
- An error occurs that blocks progress
- You discover something important
- The iteration is ending

## Signals (signalme)

**CRITICAL:** Use `signalme` to signal task lifecycle events. Ralph2 monitors these signals to detect hangs.

### signalme - Publish internal signals
```bash
# Signal task started (IMMEDIATELY after picking a task)
signalme --id task_started --content "US-001"

# Signal implementation done (BEFORE running tests)
signalme --id task_executed --content "US-001"

# Signal task finished (AFTER tests pass and commit)
signalme --id task_finished --content "US-001"
```

**Signal lifecycle:**
1. `task_started` - Right after selecting a task from prd.json
2. `task_executed` - After implementation, before running quality checks
3. `task_finished` - After all checks pass, commit done, and PRD updated

These signals are used by ralph2 to detect if an agent is hanging. If more than 3 minutes pass between `task_finished` and the next `task_started`, the iteration is forcefully terminated.

## Codex-Specific Guidelines

1. **Be explicit** - Codex works best with clear, specific instructions
2. **One change at a time** - Focus on a single task per iteration
3. **Verify before committing** - Always run tests before marking complete
4. **Use standard tools** - Prefer standard library functions over custom implementations
5. **Comment edge cases** - Add comments for non-obvious logic

## Completion

After completing a user story:
1. Update the PRD to set `passes: true` for the completed story
2. The ralph2 loop will automatically detect completion via `jq` on prd.json
3. End your response normally - another iteration will pick up the next story if needed

**Completion is determined by checking prd.json** - when all stories have `passes: true`, ralph2 will exit successfully.

## Important

- Work on ONE story per iteration
- Commit frequently with clear messages
- Keep CI green at all times
- Read the Codebase Patterns section in progress.txt before starting
- **Always use `alertme` to report task completion or errors**
- Prefer existing patterns over new approaches
