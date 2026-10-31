# Project etiquette

Keep temporary notes, screenshots, logs, and diagnostics in Git-ignored `tmp/`.
Keep permanent documentation, source, tests, and assets in their project folders.

Use `/bin/zsh Scripts/development.sh` for each development iteration: build Debug,
run the fast high-risk subset in `Scripts/critical-tests.txt`, package, restart,
then manually validate changed behavior. Reuse `.build/`; keep critical tests
fast, relevant, and free of live hardware writes.

Use `sudo /bin/zsh Scripts/helper.sh ACTION`, replacing `ACTION` with `install`,
`update`, or `uninstall`. Keep bundled operations under `Resources/Helper/`.
Run `/bin/zsh Scripts/release.sh` for major releases: Release build, all tests,
verification, and packaging after success.

Redirect validation output to `tmp/` and check the exit status. Read logs only
when a check fails; start with the relevant error excerpt. Successful checks need
only a brief result. Avoid redundant reruns. Report what passed and any remaining
manual checks; compilation alone does not verify behavior.

Bump `HelperVersion.current.revision` for helper behavior changes. Version protocol
and settings-schema changes explicitly, test migrations and rollback, and block
incompatible downgrades.
