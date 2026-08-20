# Firstmate PR target guard

This document is the authoritative contract and verification record for firstmate's default PR repository binding and observable PR-target defences.

## Configuration convergence

`bin/fm-pr-target-config.sh` owns the gitignored `gh` repository binding.

`bin/fm-bootstrap.sh` invokes it only on its locked mutable path, which makes an ordinary session start repair a missing binding without mutating configuration from a read-only session.

The script accepts only an origin that identifies `wongsuwarn/firstmate`, runs `gh repo set-default origin`, and verifies the resulting default with `gh repo set-default --view`.

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

`bin/fm-pr-create-pretool-check.sh` verifies that both wrapper entry points are active before every harness Bash tool call and rejects directly detectable `gh` or `gh-axi` PR creation that uses a command-local PATH or literal executable path without the required repository.

Malformed hook payloads, unavailable checker dependencies, checker failures, adapter spawn failures, signal termination, invalid checker responses, and missing adapter preconditions refuse the unverified shell command.

The tracked adapters cover Claude, Codex, Grok, OpenCode, Pi, and pi-signed, with pi-signed sharing Pi's extension path.

The default repository binding means an ordinary bare, unqualified PR creation resolves to `wongsuwarn/firstmate`, so the accidental inferred-upstream path that prompted this change does not recur in a converged checkout.

The wrapper and PreToolUse checks are defence in depth for invocations they observe, not a guarantee against a deliberately qualified invocation.

An absolute executable path always bypasses the PATH shim.

The supported Bash hooks still check a directly visible literal path, but dynamic path construction or execution outside those observed Bash transports can bypass local interception.

The portable regression drives the Claude and Codex stdin payloads, the Grok stdin payload, and the OpenCode and Pi CLI transports through the executable checker.

It proves bare, nested, dynamic-name, conflicting, malformed, and wrong-target PR creation are denied when they reach the wrapper, directly detectable literal-path and command-local-PATH calls receive the same target check, `gh verify` remains transparent, explicit correct-target creation is allowed, quoted text and comments do not misfire, mutable origin changes do not disable the wrapper, every harness transport verifies the boundary, Codex, OpenCode, Pi, and pi-signed refuse adapter failures, and binding application is idempotent.

Run it with:

```sh
tests/fm-pr-create-pretool-check.test.sh
```

The adapter wiring uses the same established hook mechanisms that were live-validated for the watcher-arm and cd guards: Claude's stderr-only deny hook, Codex's exit-2 hook, Grok's stdout decision object, OpenCode's thrown `tool.execute.before` error, and Pi's `{ block: true }` tool-call result.

## Worker discovery

Firstmate-repository brief scaffolds retain one short instruction that every PR must explicitly pass `--repo wongsuwarn/firstmate --base main`.

The configuration binding is the default safety layer and the wrapper plus PreToolUse checks are observable defence-in-depth layers, so this instruction is only the discoverability layer.
