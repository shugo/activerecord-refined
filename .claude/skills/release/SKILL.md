---
name: release
description: Cut a release -- pick the level, bump, tag, push, watch the gem go out
---

Release what is on `master`: choose the level from what has landed since the
last tag, bump and tag it, push, and report when RubyGems.org has it.  A
release cannot be taken back, so every step looks before it acts.  The rules
below repeat CLAUDE.md where they overlap; where they disagree, CLAUDE.md
wins.  An argument names the level -- `/release minor` -- and skips the
choice in step 2, not the checks around it.

1. Look first.  Every one of these has to hold, and the skill stops and says
   which does not rather than releasing around it:
   - `git branch --show-current` is `master`.  Releases are cut from there.
   - `git status --short` is clean.  Uncommitted work is not in the release
     and would not be in the tag; commit it (the `push` skill) or set it
     aside.
   - `git fetch origin` and then `git rev-parse HEAD origin/master` agree.
     The tag has to point at what the remote has, and what CI ran.
   - CI is green for HEAD: `gh run list --workflow test.yml --commit $(git
     rev-parse HEAD) --limit 1` says `completed success`.  Queued or running
     is not green yet -- start one background wait on its conclusion, as the
     `push` skill does, and take the release up when it lands.  Red is a
     stop.

2. Choose the level, from the commits since the last tag:

       git log --oneline $(git describe --tags --abbrev=0)..HEAD

   Read the subjects, and the bodies where a subject leaves it open.
   - *minor*: DSL surface has been added or renamed -- a new method a block
     or a symbol answers to, a new relation method, a new keyword -- or the
     meaning of a query that already worked has changed.
   - *patch*: everything else -- a fix, a new refusal of something that never
     worked right (an `ArgumentError` guard adds no surface), an adapter
     brought into line, documentation, tests, the sandbox.
   - *major* is never this skill's call.  If anything since the last tag
     breaks a query that used to work, stop and say so.
   State the level and the commits that decided it in the report.  When the
   history is only documentation and housekeeping, ask whether a release is
   wanted at all rather than cutting a patch for nothing.

3. Bump and tag, which one command does:

       bundle exec bump <level> --tag

   It rewrites `lib/active_record/refined/version.rb`, commits that one file
   with the version as the message -- `v0.9.0`, the way every release commit
   here reads, with no trailer -- and tags the commit `v0.9.0`.  It also runs
   `bundle`, which touches only the gitignored `Gemfile.lock`.  Check its
   work before pushing: `git show --stat HEAD` names version.rb alone, and
   `git tag --points-at HEAD` names the tag.  If bump committed but did not
   tag, tag by hand with `git tag v<version>`; if it did neither, nothing has
   happened and the report says why.

4. Push the commit and the tag together:

       git push --follow-tags

   Never a force-push here: a tag that reached the remote is what the
   workflow released, and rewriting it would release something else under
   the same name.

5. Watch the gem go out.  The tag runs `.github/workflows/push_gem.yml`,
   which publishes through RubyGems.org's trusted publishing in about a
   minute.  Check once -- `gh run list --workflow push_gem.yml --limit 1`
   -- and start one background wait on that run's conclusion:

       RUN=$(gh run list --workflow push_gem.yml --limit 1 --json databaseId --jq '.[0].databaseId')
       until gh run view $RUN --json status --jq .status | grep -q completed; do sleep 20; done
       gh run view $RUN --json conclusion --jq .conclusion

   Never poll in the foreground.  A red run means the tag is on the remote
   and the gem is not on RubyGems.org; report the failed step's log, and
   leave the tag where it is -- the fix is a new patch release, not a moved
   tag.

6. Report: the version, the level and why, the range the release covers
   (`v<previous>..v<new>`), and the workflow's conclusion once it arrives,
   with https://rubygems.org/gems/activerecord-refined.  Nothing else needs
   updating for a release: the sandbox rebuilds from `master` on its own
   workflow, and the README carries no version.
