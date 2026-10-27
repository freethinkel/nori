---
description: Bump nori's version and push it to main, so CI tags and publishes the release
argument-hint: "[patch|minor|major|X.Y.Z]"
---

Release a new nori version. Pushing a new `CFBundleShortVersionString` in `app/Info.plist` to `main` is the whole
release: `.github/workflows/build.yml` then signs the app with Developer ID, notarizes it, tags `v<version>` and
publishes `Nori.dmg` (what people install from and the app's updater in `daemon/Update.swift` downloads), with the commits since the last tag
as the notes (`docs:` and `release:` commits left out).

Argument: `$ARGUMENTS`. Empty means `patch`; `minor` and `major` bump that part; `X.Y.Z` is the exact version.

1. Check the state; stop and say why if any of these fail:
   - the branch is `main` and `git fetch origin` shows it is not behind `origin/main`;
   - `app/Info.plist` has no uncommitted changes (the bump commit must hold only the version);
   - the new version is greater than the current one (`make -s version`) and `v<new>` is not already a tag.
   Other uncommitted files are fine: leave them alone, do not stash or commit them.
2. Show the notes the release will get:
   `prev=$(git describe --tags --abbrev=0 2>/dev/null); git log --no-merges --format='- %s' ${prev:+$prev..}HEAD | grep -vE '^- (docs|release):'`
   (with no tag yet, every commit). If the list is empty, stop: there is nothing to release.
3. Set the version with `sed -i '' '/CFBundleShortVersionString/{n;s|<string>.*</string>|<string><new></string>|;}' app/Info.plist`
   (not `plutil -replace`: it reorders the keys), and check `make -s version` prints `<new>`.
4. `make test` and `make app`. If either fails, `git checkout app/Info.plist` and stop with the output.
5. Commit only `app/Info.plist` as `release: <new>`, then `git push origin main`.
6. Find the run with `gh run list --workflow build.yml --branch main --limit 1` and `gh run watch <id> --exit-status`
   in the background. When it ends, report the release URL (`gh release view v<new> --json url -q .url`), or the
   failing step's log (`gh run view <id> --log-failed`).
