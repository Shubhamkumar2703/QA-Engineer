# Prompt versioning

Each agent gets its own folder here. When a prompt changes, save it as a
new `vN.md` file rather than overwriting the previous version — this is
what makes the `prompt_version` field in the logging schema meaningful.
Never delete an old version; if it's no longer used, that's what git
history + this convention already tell you.
