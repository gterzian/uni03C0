# AGENTS.md

## The one rule

**Never use git except for read operations.**

Allowed (read-only):
- `git status`, `git log`, `git diff`, `git show`, `git blame`, `git grep`, `git ls-files`, `git rev-parse`, `git stash list` (and anything else that does not modify the repository).

Forbidden (anything that writes or changes state):
- `git add`, `git commit`, `git push`, `git pull`, `git fetch`, `git checkout`, `git switch`, `git reset`, `git revert`, `git rebase`, `git merge`, `git cherry-pick`, `git stash` (push/pop/drop), `git tag`, `git branch -m`, `git clean`, `git rm`, `git mv`, `git config` writes, `git init`, `git gc`, `git filter-branch`.

The human owns the repository history. If a commit (or any other write
operation) is needed, say so and let the human run it.
