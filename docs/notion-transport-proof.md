# Private Notion transport proof

The `metagent notion proof` commands are a bounded transport test, not a skill publisher. Use only the explicitly approved private synthetic target and fixture. A successful sign-in or tool listing does not prove an upload/download round trip.

Run proof commands with the installed, Apple-signed development helper:

```bash
"$HOME/Applications/Metagent Dev.app/Contents/Helpers/metagent" notion proof list
```

If that helper is missing or stale, build and install it with `scripts/install-app.sh` first. Do not use `swift run metagent`, `.build/debug/metagent`, or a copied/ad-hoc-signed binary for these commands. The helper validates its own Apple-anchored signature and disables Keychain dialogs process-wide before any Notion credential or network operation; if either check fails, the proof stops. The saved login is intended to persist between uses of the same signed helper; it should not require a fresh sign-in for each proof command. Do not put credentials or workspace-specific pilot IDs in this document.
