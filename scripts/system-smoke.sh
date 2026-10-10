#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
configuration="${1:-debug}"
bash scripts/build.sh "$configuration"
binary_dir="$(bash scripts/swift.sh build -c "$configuration" --show-bin-path)"
fixture_dir="$(mktemp -d "$PWD/dist/fileto-fixtures.XXXXXX")"
smoke_dir="$(mktemp -d "${TMPDIR:-/private/tmp}/fileto-smoke.XXXXXX")"
registrar="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
cleanup() {
    mkdir -p "$PWD/.build/ui-smoke"
    cp -R "$smoke_dir/." "$PWD/.build/ui-smoke/"
    "$registrar" -u "$fixture_dir/First.app" >/dev/null 2>&1 || true
    "$registrar" -u "$fixture_dir/Second.app" >/dev/null 2>&1 || true
    rm -rf "$fixture_dir"
    rm -rf "$smoke_dir"
}
trap cleanup EXIT
python3 scripts/create-fixtures.py "$fixture_dir"
codesign --force --sign - "$fixture_dir/First.app"
codesign --force --sign - "$fixture_dir/Second.app"
"$registrar" -f "$fixture_dir/First.app"
"$registrar" -f "$fixture_dir/Second.app"
rm -f "$PWD/.build/ui-smoke/smoke-history.json"
rm -f "$PWD/.build/ui-smoke/smoke-result.txt"
rm -f "$PWD/.build/ui-smoke/stage.txt"
if ! "$binary_dir/fileto-probe" --run-ui-smoke "$PWD/dist/Fileto.app" "$smoke_dir" "$fixture_dir/First.app" "$fixture_dir/Second.app"; then
    if [ "${FILETO_DEBUG_LS:-0}" = "1" ]; then
        "$registrar" -dump | python3 -c 'import sys; chunks=sys.stdin.read().split("--------------------------------------------------------------------------------"); print("\n".join(c for c in chunks if "com.fileto.validation" in c))'
    fi
    exit 1
fi
