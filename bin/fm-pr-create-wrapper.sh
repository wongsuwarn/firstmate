#!/usr/bin/env bash
# Transparent gh and gh-axi execution guard for firstmate PR targets.
#
# bin/shims/gh and bin/shims/gh-axi forward here from the PATH entry installed
# for every spawned harness and documented for primary launches.
#
# Usage:
#   gh <args>... or gh-axi <args>... through bin/shims
set -u

TARGET=wongsuwarn/firstmate
SELF=${BASH_SOURCE[0]}
SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$SELF")" 2>/dev/null && pwd -P) || exit 2
SHIM_DIR=$SCRIPT_DIR/shims

canonical_path() {
  local path=$1 dir
  dir=$(CDPATH='' cd -- "$(dirname -- "$path")" 2>/dev/null && pwd -P) || return 1
  printf '%s/%s\n' "$dir" "$(basename -- "$path")"
}

verify_boundary() {
  local tool found expected
  for tool in gh gh-axi; do
    found=$(command -v "$tool" 2>/dev/null) || return 1
    found=$(canonical_path "$found") || return 1
    expected=$(canonical_path "$SHIM_DIR/$tool") || return 1
    [ "$found" = "$expected" ] && [ -x "$found" ] || return 1
  done
}

is_pr_create() {
  local positional=0 arg expect_value=0
  for arg in "$@"; do
    if [ "$expect_value" -eq 1 ]; then
      expect_value=0
      continue
    fi
    case "$arg" in
      --repo|--hostname|-R) expect_value=1; continue ;;
      --repo=*|--hostname=*|-R?*) continue ;;
      --) continue ;;
      -*) continue ;;
    esac
    positional=$((positional + 1))
    if [ "$positional" -eq 1 ]; then
      [ "$arg" = pr ] || return 1
    elif [ "$positional" -eq 2 ]; then
      [ "$arg" = create ]
      return
    fi
  done
  return 1
}

has_required_target() {
  local repo_found=0 base_found=0 arg expect_repo=0 expect_base=0
  for arg in "$@"; do
    if [ "$expect_repo" -eq 1 ]; then
      [ "$arg" = "$TARGET" ] || return 1
      repo_found=1
      expect_repo=0
      continue
    fi
    if [ "$expect_base" -eq 1 ]; then
      [ "$arg" = main ] || return 1
      base_found=1
      expect_base=0
      continue
    fi
    case "$arg" in
      --) break ;;
      --repo) expect_repo=1 ;;
      --repo=*) [ "${arg#--repo=}" = "$TARGET" ] || return 1; repo_found=1 ;;
      -R|-R?*) return 1 ;;
      --base) expect_base=1 ;;
      --base=*) [ "${arg#--base=}" = main ] || return 1; base_found=1 ;;
    esac
  done
  [ "$expect_repo" -eq 0 ] && [ "$expect_base" -eq 0 ] && [ "$repo_found" -eq 1 ] && [ "$base_found" -eq 1 ]
}

resolve_real_tool() {
  local tool=$1 rest=$PATH entry candidate resolved_dir
  while [ -n "$rest" ]; do
    entry=${rest%%:*}
    if [ "$entry" = "$rest" ]; then rest=; else rest=${rest#*:}; fi
    [ -n "$entry" ] || entry=.
    resolved_dir=$(CDPATH='' cd -- "$entry" 2>/dev/null && pwd -P) || continue
    candidate=$resolved_dir/$tool
    [ -f "$candidate" ] && [ -x "$candidate" ] || continue
    case "$candidate" in
      */bin/shims/gh|*/bin/shims/gh-axi) continue ;;
    esac
    printf '%s\n' "$candidate"
    return 0
  done
  return 1
}

refuse_target() {
  printf '%s\n' "[pr-target-required] a firstmate PR must explicitly pass --repo $TARGET (and --base main)." >&2
  exit 2
}

TOOL=${FM_PR_CREATE_TOOL-}
if [ -z "$TOOL" ]; then
  case "${FM_PR_CREATE_WRAPPER_INTERNAL-}" in
    verify)
      [ "$#" -eq 0 ] || exit 2
      verify_boundary
      exit $?
      ;;
    check)
      case "${1-}" in gh|gh-axi) shift ;; *) exit 2 ;; esac
      if is_pr_create "$@" && ! has_required_target "$@"; then
        refuse_target
      fi
      exit 0
      ;;
    is-pr-create)
      case "${1-}" in gh|gh-axi) shift ;; *) exit 2 ;; esac
      is_pr_create "$@"
      exit $?
      ;;
  esac
fi
case "$TOOL" in
  gh|gh-axi) ;;
  *) echo "error: fm-pr-create-wrapper.sh must be reached through the gh or gh-axi shim" >&2; exit 2 ;;
esac

if is_pr_create "$@" && ! has_required_target "$@"; then
  refuse_target
fi
REAL_TOOL=$(resolve_real_tool "$TOOL") || { echo "error: no real $TOOL executable found after firstmate's shim" >&2; exit 2; }
exec "$REAL_TOOL" "$@"
