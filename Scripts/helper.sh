#!/bin/zsh
set -euo pipefail
[[ $# == 1 ]] || { print -u2 'Usage: helper.sh install|update|uninstall'; exit 2; }
case "$1" in
    install|update|uninstall) ;;
    *) print -u2 'Usage: helper.sh install|update|uninstall'; exit 2 ;;
esac
base="${0:A:h}"
operations="$base/Helper"
if [[ ! -d "$operations" && -f "$base/development.sh" ]]; then
    operations="$base/../dist/Battery Saver.app/Contents/Resources/Helper"
fi
[[ -f "$operations/$1.sh" ]] || { print -u2 'Bundled helper operation is missing. Build or replace the app first.'; exit 1; }
exec /bin/zsh "$operations/$1.sh"
