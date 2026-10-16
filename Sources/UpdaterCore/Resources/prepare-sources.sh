#!/bin/bash
# Bundled startup operations. Never upgrade user applications here.
set -euo pipefail
export PATH=/opt/homebrew/bin:/usr/local/bin:/opt/local/bin:/opt/local/sbin:/usr/bin:/bin:/usr/sbin:/sbin
export HOMEBREW_NO_ANALYTICS=1 HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_CLEANUP=1
export HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK=1 NONINTERACTIVE=1

fail() { printf '%s\n' "$1" >&2; exit 1; }
quote() { printf "'%s'" "${1//\'/\'\\\'\'}"; }
authorize() {
    /usr/bin/osascript -e 'on run argv' -e 'do shell script (item 1 of argv) with administrator privileges' -e 'end run' "$1"
}
brew_path() {
    case "$1" in /opt/homebrew/bin/brew|/usr/local/bin/brew) ;; *) fail "Unsupported Homebrew location." ;; esac
}
case "${1:-}" in
    brew-update|mas-install|mas-update)
        [[ $# == 2 ]] || fail "Unexpected startup arguments."
        brew_path "$2"
        case "$1" in
            brew-update) exec "$2" update ;;
            mas-install) exec "$2" install --formula mas ;;
            mas-update) exec "$2" upgrade --formula mas ;;
        esac
        ;;
    ports-update)
        [[ $# == 1 ]] || fail "Unexpected startup arguments."
        authorize '/opt/local/bin/port -N selfupdate'
        ;;
    ports-mas-update)
        [[ $# == 1 ]] || fail "Unexpected startup arguments."
        authorize '/opt/local/bin/port -N -k upgrade mas'
        ;;
    install-package)
        [[ $# == 3 && "$2" == /*.pkg && "$3" =~ ^[a-f0-9]{64}$ ]] || fail "Invalid installer arguments."
        # Recheck integrity and Gatekeeper in the authorized process as well.
        pkg=$(quote "$2")
        digest=$(quote "$3")
        authorize "test \"\$(/usr/bin/shasum -a 256 $pkg | /usr/bin/awk '{print \$1}')\" = $digest && /usr/sbin/spctl --assess --type install $pkg && /usr/sbin/installer -pkg $pkg -target /"
        ;;
    *) fail "Unknown startup operation." ;;
esac
