# Releasing

The maintainer's guide. If you only want to *install* a particular release, the
[Releases](../README.md#releases) section of the README is what you want.

Cutting a release is two commands and a push. Everything before the push is
local and undoable; the push is the only irreversible step, which is why
`make release` never does it for you.

---

## The normal flow

**1. As you work**, add a line to `## [Unreleased]` in
[`CHANGELOG.md`](../CHANGELOG.md) describing the change the way a *user* would
experience it. Not "refactor deploy_dir" — "a module removed from the repo no
longer leaves a dangling symlink". Mark anything that renames or removes an
alias, function or flag as **BREAKING**.

This is not bookkeeping for its own sake: `make release` refuses while that
section is empty, so a release cannot ship without saying what changed.

**2. When you are ready:**

```sh
make release-dry VERSION=1.1.0     # runs every check, shows the exact diff, writes nothing
make release VERSION=1.1.0         # stamps VERSION, rewrites CHANGELOG, commits, tags
git push --follow-tags origin main
```

`--follow-tags` pushes the commits *and* the annotated tag in one go. That push
is what starts the release.

### Choosing the number

| Bump | When |
|---|---|
| **major** | An alias, function or script flag was renamed or removed. Someone's muscle memory breaks. |
| **minor** | New aliases, functions, flags or modules. Nothing that already worked stops working. |
| **patch** | Fixes, documentation, and internal changes with no user-visible surface. |

---

## What `make release` checks, and why

Each refusal names what to do instead. They exist because every one of them has
a way of biting at the worst moment:

| It refuses when | Because |
|---|---|
| the version is not `X.Y.Z` | a typo'd tag is public forever |
| you are not on `main` | releases come from the branch CI protects |
| the working tree is dirty | untracked files are usually something that belonged in the release |
| local `main` is behind `origin/main` | you would tag a tree that is missing commits |
| `HEAD` is already tagged | a release was cut and never pushed — push that one instead |
| the tag exists locally or on origin | versions are never reused |
| the version is not greater than `VERSION` | versions only go up |
| `## [Unreleased]` is empty | a release with no notes is not a release |
| `make check` fails | never tag a red tree |

It also warns — rather than refusing — when the container round trip **skipped**
because Docker was not running. `make check` passes either way, so without that
warning a release could look fully tested when the container suite never ran.
CI still runs it on the tag, so this is a heads-up, not a blocker. Use
`--no-docker` to skip it deliberately.

---

## What happens after the push

The tag push starts a second CI run (the branch push starts its own). On the
tag run:

1. `lint`, `unit` and `roundtrip` run against the tag itself.
2. `release` waits for all three — nothing is published from a red build.
3. It checks the tag matches the `VERSION` file in that tree, and refuses if not.
4. It extracts the notes with `tools/release.sh --notes "$(cat VERSION)"` — the
   same code path that wrote the tag message — and publishes the GitHub Release.

So the release body, the tag message and `CHANGELOG.md` are the same text by
construction, not by discipline.

---

## When something goes wrong

| Situation | What to do |
|---|---|
| **The release job failed after the tag is public.** | The visible state is "tag exists, no release" — nothing is half-published. Re-run the job: the publish step checks `gh release view` first, so it is safe to run twice. |
| **The tag is genuinely wrong.** | `git push --delete origin v1.1.0 && git tag -d v1.1.0`, fix `main`, cut again. Only do this if no release was published; a version that has a public release is never reused. |
| **`git commit` or `git tag` failed mid-release.** | Nothing was pushed, so everything is local. `git restore --staged --worktree VERSION CHANGELOG.md`, or `git reset --hard HEAD~1` if the commit was made. |
| **You cut a release and never pushed it.** | The next `make release` tells you so and quotes the push command. Or drop it: `git tag -d v1.1.0 && git reset --hard HEAD~1`. |
| **A stray `.VERSION.XXXXXX` is left in the repo.** | A crashed run before the cleanup trap fired. It is deliberately not git-ignored, so the next release refuses on "working tree is not clean" and `git status` names it. Delete it. |
| **You tagged by hand and the tag does not match `VERSION`.** | CI's release job fails with an explicit error before publishing anything. Delete the tag and use `make release`. |

---

## Why `v1.0.0` has no `release v1.0.0` commit

Every release from `v1.0.1` onward has a matching `release vX.Y.Z` commit that
stamps `VERSION` and dates the changelog heading. `v1.0.0` does not, and that is
not a mistake.

`VERSION` and the `## [1.0.0]` section were both written by hand to seed the
process — so at that point `make release VERSION=1.0.0` correctly refused
("1.0.0 is not newer than the current version 1.0.0"), and there was nothing to
promote. The first tag was made directly from the same notes:

```sh
git tag -a v1.0.0 --cleanup=whitespace -F <(printf 'v1.0.0\n\n'; bash tools/release.sh --notes 1.0.0)
```

`--cleanup=whitespace` matters: git's default message cleanup strips every line
beginning with `#`, which would have silently eaten all the `### Added` headings.

This is a one-off. Nothing else needs it, and `make release` handles every
release after the first.
