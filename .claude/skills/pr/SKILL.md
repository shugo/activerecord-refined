---
name: pr
description: Open a pull request from the current branch, this repository's way
---

Open a pull request for the branch the conversation just finished, against
`master`, and report its URL.  The repository's rule is that Shugo opens the
pull requests himself; invoking this skill is that ask, so it goes ahead.
The rules below repeat CLAUDE.md where they overlap; where they disagree,
CLAUDE.md wins.

1. Look first, with `gh` for GitHub and `git` for the tree:
   - The branch is the head.  Refuse to open one from `master`; the change
     belongs on a branch of its own first.
   - `git status --short` should be clean.  Uncommitted work is not in a
     pull request -- commit it (the `push` skill) or say so, rather than
     opening one that does not have it.
   - `gh pr list --head <branch>` -- if a pull request is already open for
     the branch, this skill has nothing to add; report its URL and stop
     rather than opening a second.

2. Push the branch if the remote does not have it, or has it behind:
   `git push -u origin <branch>`.  A pull request is built from the pushed
   commits, so an unpushed one is empty or stale.  Before any force-push,
   verify the remote SHA with `git ls-remote` and use `--force-with-lease`.

3. Write the title and body.  English, and ASCII as the commit messages are.
   - Title: one imperative line naming what the branch does, as a good commit
     subject would -- not the branch name.
   - Body: what changed and why, drawn from the branch's own commits
     (`git log master..<branch>`), and how it was verified -- which adapters
     the suite ran green on, what CI says.  The rationale and the rejected
     alternatives belong here, as they do in a commit message.
   - End at the last line of that prose.  No "Generated with" line, no
     session URL, no trailer -- the same restraint the commit messages keep.
   - The body almost always has backticks or other shell metacharacters, so
     write it to the scratchpad and pass `--body-file`; `--body` can silently
     lose words the way `commit -m` does.

4. Open it: `gh pr create --base master --head <branch> --title <title>
   --body-file <file>`.  `master` is the base; the gemspec and CI already
   run against it.

5. Report the pull request URL, and let Shugo take it from there -- reviewing
   and merging are his, as opening one usually is.
