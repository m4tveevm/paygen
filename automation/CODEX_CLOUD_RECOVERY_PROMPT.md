# Resume Paygen

Read IMPLEMENTATION_STATUS.md and VERIFICATION.md, inspect the working tree and
the latest CI run for dev/paygen-reference, then read REQUIREMENTS.md and
automation/ORIGINAL_PLAN.md. Continue the recorded next step without recreating
completed phases. Preserve all local user changes. Re-check prior evidence when
code affecting that gate changed. Run script/verify-complete before COMPLETE.
Read CODEX_CLOUD_MASTER_PROMPT.md for agent ownership, model preferences and the
maximum three-subagent policy. Preserve the session continuation counter; stop
and checkpoint at 48 continuations or 24 hours of one cloud run. Start a new
run's counter only when a new session has actually begun.

A timeout, unavailable toolchain or closed agent session is not successful
completion. Save precise unresolved gates and the next action before yielding.
