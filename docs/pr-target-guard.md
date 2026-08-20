# Firstmate PR target guard

This document is the authoritative contract and verification record for preventing a firstmate checkout from creating a PR against an inferred upstream repository.

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

## PreToolUse refusal

`bin/fm-pr-create-command-policy.mjs` is the sole command classifier.

It reuses the shell lexer from `bin/fm-arm-command-policy.mjs` and refuses direct `gh` or `gh-axi` `pr create` calls unless they include the literal `--repo wongsuwarn/firstmate` target.

The refusal tells the worker to pass `--repo wongsuwarn/firstmate --base main`.

The tracked harness wiring scopes `bin/fm-pr-create-pretool-check.sh` to firstmate checkouts, independently of mutable remote configuration, and the script renders the existing harness-specific deny responses.

A malformed or otherwise unclassifiable command that appears to create a PR is refused rather than allowed.

Malformed hook payloads, unavailable classifier dependencies, classifier failures, and invalid classifier responses also refuse the unverified shell command.

The tracked adapters cover Claude, Codex, Grok, OpenCode, Pi, and pi-signed, with pi-signed sharing Pi's extension path.

The portable regression drives the Claude and Codex stdin payloads, the Grok stdin payload, and the OpenCode and Pi CLI transports through the executable checker.

It proves bare, nested, conflicting, and wrong-target PR creation are denied, explicit correct-target creation is allowed directly and through a literal shell payload, unrelated commands are allowed, mutable origin changes do not disable enforcement, transport and classifier failures refuse unverified commands, malformed PR creation is refused, and binding application is idempotent.

Run it with:

```sh
tests/fm-pr-create-pretool-check.test.sh
```

The adapter wiring uses the same established hook mechanisms that were live-validated for the watcher-arm and cd guards: Claude's stderr-only deny hook, Codex's exit-2 hook, Grok's stdout decision object, OpenCode's thrown `tool.execute.before` error, and Pi's `{ block: true }` tool-call result.

## Worker discovery

Firstmate-repository brief scaffolds retain one short instruction that every PR must explicitly pass `--repo wongsuwarn/firstmate --base main`.

The configuration binding is the default safety layer and the PreToolUse guard is the refusal layer, so this instruction is only the discoverability layer.
