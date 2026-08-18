---
name: push
description: Commit the finished change and push it, this repository's way
---

Commit what the conversation just finished, push it, and report. The rules
below repeat CLAUDE.md where they overlap; where they disagree, CLAUDE.md
wins.

1. Look first: `git status --short` and `git diff --stat`. Stage files by
   name -- never `git add -A`; sandbox/ generates tens of thousands of
   gitignored files and one slip has already cost a history rewrite.
   Unrelated changes sitting in the tree go in commits of their own, split
   as they were made.

2. Write the message: English, imperative mood. The rationale, the rejected
   alternatives and anything measured belong here rather than in code
   comments. End with a single trailer naming the model actually in use,

       Co-Authored-By: Claude <model> <noreply@anthropic.com>

   and nothing after it -- no session URLs, no "Generated with" lines. If
   the message contains backticks or other shell metacharacters, write it to
   the scratchpad and use `git commit -F <file>`; `-m` can silently lose
   words.

3. Push. Before any force-push, verify the remote SHA with `git ls-remote`
   and use `--force-with-lease`.

4. Check CI exactly once: `gh run list --limit 2`, and report what it says
   -- the new run is usually still queued, which is fine to say. Never poll
   in a loop in the foreground. When this push's outcome genuinely matters
   (lib/ or CI config changed, or the last run was red), start one
   background wait on the run's conclusion and report when it completes:

       RUN=$(gh run list --workflow test.yml --limit 1 --json databaseId --jq '.[0].databaseId')
       until gh run view $RUN --json status --jq .status | grep -q completed; do sleep 20; done
       gh run view $RUN --json conclusion --jq .conclusion

5. Report the pushed range (`old..new`) and the commit subject.
