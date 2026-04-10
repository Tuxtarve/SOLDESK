#!/usr/bin/env bash
TICKETING_REPO_ROOT="${TICKETING_REPO_ROOT:-"$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"}"
alias img='bash "$TICKETING_REPO_ROOT/scripts/img.sh"'
