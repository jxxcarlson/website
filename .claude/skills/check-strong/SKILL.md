---
name: check-strong
description: Comprehensive review of uncommitted changes or recent commits using specialized agents
argument-hint: "[--last N] [aspects: code|errors|comments|types|tests|simplify|all]"
allowed-tools: ["Bash", "Glob", "Grep", "Read", "Task"]
---
# Comprehensive Review of Changes

Review uncommitted changes or recent commits using specialized agents. Each agent focuses on a specific aspect of code quality.

**Arguments:** "$ARGUMENTS"
- `--last N` - Review the last N commits (default: uncommitted changes only)
- Aspects: code, errors, comments, types, tests, simplify, all

## Context

Parse arguments to determine the diff target:
- If `--last N` specified: use `git diff HEAD~N..HEAD`
- Otherwise: use `git diff HEAD` (uncommitted changes)

- Git status: `git status --short`
- Changed files: `git diff --name-only <target>`
- Diff to review: `git diff <target>`

## Instructions

1. **Parse arguments** from "$ARGUMENTS":
   - Extract `--last N` if present (N = number of commits)
   - Remaining arguments are review aspects

2. **Determine which agents to run** based on aspects and changed files:
   | Aspect | Agent (subagent_type) | When applicable |
   |--------|----------------------|-----------------|
   | `code` | `pr-review-toolkit:code-reviewer` | Always - general quality review |
   | `errors` | `pr-review-toolkit:silent-failure-hunter` | If error handling code changed |
   | `comments` | `pr-review-toolkit:comment-analyzer` | If comments/docs added or modified |
   | `types` | `pr-review-toolkit:type-design-analyzer` | If new types introduced |
   | `tests` | `pr-review-toolkit:pr-test-analyzer` | If test files changed |
   | `simplify` | `code-simplifier:code-simplifier` | After other reviews pass |

3. **Launch agents using the Task tool**:
   - Tell each agent to review the appropriate diff range
   - Run sequentially by default, or in parallel if user specifies "parallel"
   - Each agent returns its own detailed report

4. **Aggregate and summarize** the findings:
   - **Critical Issues** - must fix before commit
   - **Important Issues** - should fix
   - **Suggestions** - consider
   - **Strengths** - what's done well

## Usage
```
/check-strong                    # Review uncommitted changes
/check-strong --last 1           # Review the last commit
/check-strong --last 3           # Review the last 3 commits
/check-strong --last 2 code      # Last 2 commits, code review only
/check-strong code errors        # Uncommitted changes, specific aspects
/check-strong --last 5 all parallel  # Last 5 commits, all agents in parallel
```

## Notes

- This is the thorough version - use `/check` for quick lightweight review
- Agents analyze only the specified diff range, not the whole codebase
- Results include specific file:line references

