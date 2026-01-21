---
name: commit
description: Stage and commit changes to git with a descriptive message
---

Create a git commit for the current changes:

1. Run `git status` to see all changed and untracked files
2. Run `git diff` to review the changes
3. Run `git log --oneline -5` to see recent commit message style
4. Stage relevant files with `git add`
5. Create a commit with a clear, concise message describing the changes

End the commit message with:
```
Co-Authored-By: Claude Opus 4.5 <noreply@anthropic.com>
```

Do not push to remote unless explicitly asked.
