# Autonomous development and recovery

Use CODEX_CLOUD_MASTER_PROMPT.md for a fresh implementation session and
CODEX_CLOUD_RECOVERY_PROMPT.md to resume. Attach the original case PDF and API
YAML if they are unavailable in the selected environment. PLAN.md is preserved
as ORIGINAL_PLAN.md; generated status and evidence live at repository root.

CONTINUE means there is actionable implementation/testing work. COMPLETE requires
all full-plan gates. HARD_BLOCKER identifies an external prerequisite that cannot
be resolved inside the run. INCOMPLETE_RESUMABLE preserves a platform-limited run.
There is no local supervisor pretending to restart a cloud task.
