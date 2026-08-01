# Repository Guidelines

## Scope

Signalbox is an attention-first Neovim control surface for Herdr. Keep Herdr responsible for PTYs, process persistence, and semantic agent state. Keep Signalbox focused on transient Neovim UI, notifications, editor context, and explicit user actions.

## Local Verification Before Commit

Do not use a commit or a pushed CI run as the first validation of a change.

Before every commit:

1. Read `.github/workflows/ci.yml` and run the same project check locally:

   ```sh
   make check
   git diff --check
   ```

2. When `act` and Docker are available, run the CI job locally so its pinned tools and Neovim matrix execute before commit:

   ```sh
   act pull_request --job check \
     --container-architecture linux/amd64 \
     -P ubuntu-latest=catthehacker/ubuntu:act-latest
   ```

3. If a matrix entry cannot run locally, record which entry was not reproduced and why. Run every feasible equivalent locally, then verify the unreproduced entry in GitHub Actions after push.
4. Reproduce UI changes with the actual Neovim configuration and provider involved, in addition to the clean headless test suite. For float changes, check focus, dimensions, z-index, window identity across resize, and the destination after the modal closes.
5. Reproduce Herdr integration changes against a disposable workspace or agent and remove test resources afterward.

Only commit after the relevant local checks pass and the final diff has been inspected.

## Style and Tests

- Use StyLua and Luacheck through `make check`.
- Keep Neovim 0.10 compatibility unless the documented requirement changes.
- Add a focused regression test for every fixed bug when the behavior can be observed through the Neovim API.
- Keep external commands as argv arrays. Never interpolate editor or prompt contents into a shell command.
- Preserve unrelated user changes in a dirty worktree.

## Release

Create a release only from a clean, reviewed commit whose local CI-equivalent checks passed. After pushing, wait for every GitHub Actions matrix entry on that exact commit to succeed before creating the tag and release.
