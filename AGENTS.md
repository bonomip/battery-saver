# Project etiquette

- Keep temporary notes, images, logs, and diagnostics in Git-ignored `tmp/`.
- After implementing a feature, run only `/bin/zsh Scripts/development.sh`. It
  builds Debug, runs critical tests, packages, and restarts the app. Do not add
  separate validation runs unless Paolo asks or a failure requires diagnosis.
- Paolo owns visual debugging and acceptance. No screenshots, previews, or visual
  inspection unless explicitly requested. Hand off the running Debug app.
- Redirect output to `tmp/`. Check exit status; read logs only on failure.
  Report success briefly. Reuse `.build/` and avoid redundant reruns.
- Use `/bin/zsh Scripts/release.sh` for major releases only.
- Manage helpers with `sudo /bin/zsh Scripts/helper.sh ACTION`, choosing `install`,
  `update`, or `uninstall`. Bundled operations live in `Resources/Helper/`.
- Bump helper revision for behavior changes. Version protocol/schema changes,
  test migration and rollback, and block incompatible downgrades.
