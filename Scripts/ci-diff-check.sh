#!/bin/zsh
set -euo pipefail

event_name=${GITHUB_EVENT_NAME:-}
base_commit=

case "$event_name" in
    pull_request)
        base_ref=${GITHUB_BASE_REF:-}
        if [[ -z "$base_ref" ]] \
            || ! /usr/bin/git check-ref-format --branch "$base_ref" >/dev/null 2>&1; then
            print -u2 "CI base branch is invalid"
            exit 64
        fi
        base_commit=$(/usr/bin/git merge-base "refs/remotes/origin/$base_ref" HEAD)
        ;;
    push)
        before=${GITHUB_EVENT_BEFORE:-}
        nonzero=${before//0/}
        if [[ -n "$before" \
            && -n "$nonzero" \
            && "$before" =~ '^[0-9a-fA-F]{40}([0-9a-fA-F]{24})?$' ]] \
            && /usr/bin/git cat-file -e "${before}^{commit}" 2>/dev/null; then
            base_commit=$(/usr/bin/git rev-parse --verify "${before}^{commit}")
        else
            base_commit=$(/usr/bin/git rev-parse --verify 'HEAD^{commit}^')
        fi
        ;;
    *)
        print -u2 "CI event is unsupported"
        exit 64
        ;;
esac

/usr/bin/git diff --check "$base_commit...HEAD"
