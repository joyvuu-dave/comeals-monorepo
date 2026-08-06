# Shared terminal output helpers for bin/check and bin/deploy.
# Source from a script that has already cd'd to the repo root:
#
#   . bin/lib/output.sh
#
# Both scripts carried their own copy of these; a styling tweak had to
# be made twice (#52).

red()    { printf "\033[0;31m%s\033[0m\n" "$*"; }
green()  { printf "\033[0;32m%s\033[0m\n" "$*"; }
yellow() { printf "\033[0;33m%s\033[0m\n" "$*"; }
bold()   { printf "\033[1m%s\033[0m\n" "$*"; }

step() { printf "\n"; bold "==> $*"; }
info() { echo "    $*"; }
warn() { yellow "    ⚠ $*"; }
fail() { red "    ✗ $*"; }

# The success line: bin/check calls it pass, bin/deploy calls it ok.
pass() { green "    ✓ $*"; }
ok()   { pass "$@"; }
