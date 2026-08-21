Mode: Grok Stop-owned supervision.

When this session owns supervision and away mode is not active:
1. Drain first with `bin/fm-wake-drain.sh`.
2. The Grok Stop hook runs `bin/fm-grok-stop-autoarm.sh` in the foreground between turns and sources the effective X-mode environment itself when needed.
3. The hook starts and verifies one home-scoped `bin/fm-watch-arm.sh` owner whenever work remains in flight or X mode needs polling.
4. The hook keeps that owner live until an actionable watcher close, then exits 2 so Grok delivers the wake in the same session.
5. After the handling turn stops, the hook starts the next owner without a model background-task call.
6. A redundant attach may exit only after the arm layer verified an existing live owner for this home.
7. An orphaned watcher remains attached in the Stop-owned arm rather than becoming an immediate attach completion.
8. Failure or missing cycle only: the Stop hook blocks the turn with an automatic-recovery failure, and its next Stop retries the automatic mechanism.
9. Never use shell `&` for firstmate supervision.
10. Never bundle the arm onto another command.
11. A shell `&`, a truncating pipe, or bundling is denied automatically by the PreToolUse seatbelt (`bin/fm-arm-pretool-check.sh`) whenever this project's Grok hooks are trusted.

When a Stop-hook wake resumes the session:
1. Run `bin/fm-wake-drain.sh` first.
2. Handle `signal`, `stale`, `check`, or `heartbeat` using the harness-neutral contract in `AGENTS.md`.
3. Do not manually re-arm after an ordinary wake.
4. Do not invent a wake from an attach-status line alone.
5. Drain the queue and act only on real wake records, the drain's `OPEN DECISIONS` entries, or a real watcher reason line.
6. See [`watcher-continuity.md`](../watcher-continuity.md) for the arm-layer successor and clean-close failure contract.

The primary project Stop hook runs `bin/fm-turnend-guard-grok.sh` as a backstop, not the normal wake path.
[`turnend-guard.md`](../turnend-guard.md) owns its running-payload capability selection between native same-process blocking and the pre-native bounded resume fallback.
The banner remains an alarm for a broken automatic mechanism, not a routine re-arm instruction.

Interactive TUI primary sessions are the supported supervision host.
Headless `grok -p` may wait for Stop-hook completion but does not reliably surface full auto-wake model output, so do not run the primary firstmate as a one-shot headless process.
