# Firstmate PR target guard

This document records maintainer verification for firstmate's default PR repository binding and observable PR-target defences.

## Configuration convergence

`bin/fm-pr-target-config.sh` owns the gitignored `gh` repository binding.

`bin/fm-bootstrap.sh` invokes it with the effective bootstrap root only on its locked mutable path, which makes an ordinary session start repair a missing binding in the selected checkout without mutating configuration from a read-only session.

The script accepts only an origin that identifies `wongsuwarn/firstmate`, runs `gh repo set-default origin`, and verifies the resulting default with `gh repo set-default --view`.

It does not rewrite the origin URL or read, rewrite, or remove the upstream remote.

It is idempotent because `gh repo set-default origin` repeatedly writes the same `remote.origin.gh-resolved=base` repository configuration value.

On 2026-08-20, gh 2.97.0 was verified in a scratch Git repository carrying `origin=https://github.com/wongsuwarn/firstmate.git` and the third-party upstream remote.

```sh
$ gh --version | head -1
gh version 2.97.0 (2026-07-31)
$ gh repo set-default origin
$ git config --get remote.origin.gh-resolved
base
$ gh repo set-default --view
wongsuwarn/firstmate
```

`gh repo set-default --help` identifies this default as the repository used for creating pull requests, so this is the installed CLI's demonstrated bare-PR resolution path rather than an assumed configuration key.

## Defence-in-depth refusal

`bin/fm-pr-create-wrapper.sh` owns the PR-target decision for calls that reach the tracked PATH shims.

The tracked `bin/shims/gh` and `bin/shims/gh-axi` entry points validate the actual expanded argument vector and refuse `pr create` unless every `--repo` occurrence names `wongsuwarn/firstmate`.

The refusal tells the worker to pass `--repo wongsuwarn/firstmate --base main`.

`bin/fm-spawn.sh` already places `bin/shims` first on every spawned harness PATH, and the primary launch instructions export the same tracked PATH entry before starting any supported primary harness.

Because enforcement occurs when `gh` or `gh-axi` executes, dynamic command names reach the same guard while quoted examples, comments, and other non-executed text remain unrelated commands.

`bin/fm-pr-create-visible-check.sh` uses the shared tracked parser to identify directly detectable top-level `gh` or `gh-axi` PR creation, including supported command wrappers, a command-local PATH, or a literal executable path.

`bin/fm-pr-create-hook-dispatch.sh` gives every tracked harness the same checker-failure behavior.

It allows unrelated shell commands without requiring shims on PATH.

For visible PR creation, it rejects a missing or wrong `--repo wongsuwarn/firstmate` or `--base main`, then verifies both wrapper entry points before allowing the command.

When the wrapper, Node runtime, policy file, checker executable, or checker process is unavailable, the hook allows the command and emits a `pr-target-classification-unavailable` diagnostic naming the failed prerequisite and stating that classification did not run.

The same loud allowance applies when the hook payload cannot be classified or the parser exits abnormally.

The guard does not approximate shell parsing when the tracked parser is unavailable.

When parsing succeeds, a visible target violation is refused, and an unavailable tracked PATH-shim execution boundary refuses only the visible PR creation that needs it.

The tracked adapters cover Claude, Codex, Grok, OpenCode, Pi, and pi-signed, with pi-signed sharing Pi's extension path.

Kimi has no project-level hook configuration and therefore has no tracked primary PreToolUse transport; [`turnend-guard.md`](turnend-guard.md) owns that hook-surface limit.

The Claude, Codex, and Grok shell transports emit the same loud allowance when their project root or dispatcher precondition is unavailable.

The default repository binding means an ordinary bare, unqualified PR creation resolves to `wongsuwarn/firstmate`, so the accidental inferred-upstream path that prompted this change does not recur in a converged checkout.

The wrapper and PreToolUse checks are defence in depth for invocations they observe, not a guarantee against execution that bypasses both the observed hooks and the tracked PATH shims.

An absolute executable path always bypasses the PATH shim.

The supported Bash hooks check directly visible literal paths across top-level shell-list nodes but do not recurse into nested shell payloads, while dynamic path construction or execution outside those observed Bash transports can also bypass local interception.

The portable regression drives the Claude and Codex stdin payloads, the Grok stdin payload, and the OpenCode and Pi CLI transports through the executable checker.

It proves bare, nested, dynamic-name, conflicting, malformed, and wrong-target PR creation are denied when they reach the wrapper, directly detectable supported-wrapper, literal-path, and command-local-PATH calls receive the same target check, `gh verify` remains transparent, explicit correct-target creation is allowed, and quoted text, comments, and heredoc bodies do not misfire.

It also proves mutable origin changes do not disable the wrapper, every tracked primary PreToolUse transport scopes boundary enforcement to visible PR creation, unavailable classification prerequisites allow commands with a loud diagnostic through every tracked adapter, binding application is idempotent, and bootstrap root overrides repair the selected checkout.

Run it with:

```sh
tests/fm-pr-create-pretool-check.test.sh
```

On 2026-08-20, that portable regression completed with:

```text
ok - gh and gh-axi wrappers enforce expanded PR arguments without matching quoted text or comments
ok - private boundary verification does not reserve the public gh verify command
ok - detectable top-level literal-path and command-local-PATH PR calls receive target checks
ok - unavailable parser prerequisites allow commands with a loud diagnostic
ok - every primary harness transport scopes boundary enforcement to visible PR creation
ok - PR target wrapper remains active when the checkout origin changes
ok - malformed PR-target hook transport allows with a loud diagnostic
ok - OpenCode allows checker failures with a loud diagnostic
ok - Claude and Grok allow checker failures with a loud diagnostic
ok - Pi and pi-signed allow checker failures with a loud diagnostic
ok - Codex allows unavailable preconditions with a loud diagnostic
ok - PR target binding converges a clone and remains idempotent through its executable interface
ok - bootstrap root override binds and verifies the selected checkout
```

The adapter wiring uses the same established hook mechanisms that were live-validated for the watcher-arm and cd guards: Claude's stderr-only deny hook, Codex's exit-2 hook, Grok's stdout decision object, OpenCode's thrown `tool.execute.before` error, and Pi's `{ block: true }` tool-call result.

## Worker discovery

Firstmate-repository brief scaffolds retain one short instruction that every PR must explicitly pass `--repo wongsuwarn/firstmate --base main`.

The configuration binding is the default safety layer and the wrapper plus PreToolUse checks are observable defence-in-depth layers, so this instruction is only the discoverability layer.
