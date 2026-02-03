# Ralph2 Agent Instructions (Claude Code)

You are an autonomous coding agent working on a software project.

## Your Task

1. Read the PRD at `prd.json` (in the same directory as this file)
2. Read the progress log at `progress.txt` (check Codebase Patterns section first)
3. Check you're on the correct branch from PRD `branchName`. If not, check it out or create from main.
4. Pick the **highest priority** user story where `passes: false`
5. Implement that single user story
6. Run quality checks (e.g., typecheck, lint, test - use whatever your project requires)
7. Update CLAUDE.md files if you discover reusable patterns (see below)
8. If checks pass, commit ALL changes with message: `feat: [Story ID] - [Story Title]`
9. Update the PRD to set `passes: true` for the completed story
10. Append your progress to `progress.txt`
11. **Send completion alert using `alertme`** (see Notifications section)

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

If you discover a **reusable pattern** that future iterations should know, add it to the `## Codebase Patterns` section at the TOP of progress.txt (create it if it doesn't exist). This section should consolidate the most important learnings:

```
## Codebase Patterns
- Example: Use `sql<number>` template for aggregations
- Example: Always use `IF NOT EXISTS` for migrations
- Example: Export types from actions.ts for UI components
```

Only add patterns that are **general and reusable**, not story-specific details.

## Update CLAUDE.md Files

Before committing, check if any edited files have learnings worth preserving in nearby CLAUDE.md files:

1. **Identify directories with edited files** - Look at which directories you modified
2. **Check for existing CLAUDE.md** - Look for CLAUDE.md in those directories or parent directories
3. **Add valuable learnings** - If you discovered something future developers/agents should know:
   - API patterns or conventions specific to that module
   - Gotchas or non-obvious requirements
   - Dependencies between files
   - Testing approaches for that area
   - Configuration or environment requirements

**Do NOT add:**
- Story-specific implementation details
- Temporary debugging notes
- Information already in progress.txt

Only update CLAUDE.md if you have **genuinely reusable knowledge** that would help future work in that directory.

## Quality Requirements

- ALL commits must pass your project's quality checks (typecheck, lint, test)
- Do NOT commit broken code
- Keep changes focused and minimal
- Follow existing code patterns

## Notifications (alertme & promptme)

**IMPORTANT:** Use `alertme` at the end of each task to notify the user of progress.

### alertme - Send notifications
```bash
# On task completion
alertme --title "Task Complete" --description "US-001: Add priority field" --status success

# On error
alertme --title "Task Failed" --description "Build errors in component X" --status error

# Status options: success, info, warning, error
```

### promptme - Get user input (when truly needed)
```bash
# Ask a question and wait for response
ANSWER=$(promptme --title "Clarification Needed" --description "Should I use approach A or B?" --timeout 300)
echo "User said: $ANSWER"
```

**Always send an alert when:**
- A task is completed successfully
- An error occurs that blocks progress
- You need to pause for user input
- The iteration is ending

## Browser Testing (If Available)

For any story that changes UI, verify it works in the browser if you have browser testing tools configured (e.g., via MCP):

1. Navigate to the relevant page
2. Verify the UI changes work as expected
3. Take a screenshot if helpful for the progress log

If no browser tools are available, note in your progress report that manual browser verification is needed.

## Stop Condition

After completing a user story, check if ALL stories have `passes: true`.

If ALL stories are complete and passing, reply with:
<promise>COMPLETE</promise>

If there are still stories with `passes: false`, end your response normally (another iteration will pick up the next story).

## Important

- Work on ONE story per iteration
- Commit frequently
- Keep CI green
- Read the Codebase Patterns section in progress.txt before starting
- **Always use `alertme` to report task completion or errors**
