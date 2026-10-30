#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
if (( EUID != 0 )); then
    print -u2 'Run: sudo /bin/zsh Scripts/install.sh'
    exit 1
fi
exec /bin/zsh "$PWD/dist/Battery Saver.app/Contents/Resources/install-helper.sh"
