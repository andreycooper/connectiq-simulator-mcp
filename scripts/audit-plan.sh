#!/bin/sh
set -eu

root="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$root"

failed=0

check_absent() {
    description=$1
    pattern=$2
    shift 2

    set +e
    matches=$(rg -n -- "$pattern" "$@" 2>&1)
    status=$?
    set -e
    if [ "$status" -eq 0 ]; then
        echo "plan audit failed: $description" >&2
        echo "$matches" >&2
        failed=1
    elif [ "$status" -gt 1 ]; then
        echo "plan audit could not check $description" >&2
        echo "$matches" >&2
        failed=1
    fi
}

obsolete_dependency='fr''om[[:space:]]*:'
superseded_menu='Simu''lation'
unfinished='TO''DO|FIX''ME|T''BD|<NA''ME>|adjust until it ''works|implementation-''time'
hidden_status='swift (build|test)[^|]*\|'
remove_before_rename='removeItem\(at(Path)?:[[:space:]]*target|rm -f[^\n]*target[^\n]*rename'
fixed_readiness='Task\.sleep|sleep\(for:[[:space:]]*\.seconds\([12]\)'
incidental_pixels='(png|screenshot)[^\n]*(count|isEmpty|!=)|whole.image|nonblank'

check_absent "obsolete dependency declarations" "$obsolete_dependency" Package.swift
check_absent "the superseded GPS menu title" "$superseded_menu" Sources Tests/fixtures README.md
check_absent "unfinished implementation markers" "$unfinished" Sources README.md Makefile scripts
check_absent "build or test commands hidden by an output pipeline" "$hidden_status" Makefile scripts README.md
check_absent "target removal before rename" "$remove_before_rename" Sources
check_absent "fixed readiness delays" "$fixed_readiness" Sources/SimulatorMCPCore/Sim Sources/SimulatorMCPCore/Automation
check_absent "incidental screenshot assertions" "$incidental_pixels" Tests/SimulatorMCPCoreTests/Integration

foundation_process='Foundation.''Process'
allowed_process_file='Sources/SimulatorMCPCore/Support/Subprocess.swift'
process_constructor='(^|[^[:alnum:]_])Pro''cess[[:space:]]*\('
set +e
process_files=$(rg -l -- "$process_constructor" Sources 2>&1)
process_status=$?
set -e
if [ "$process_status" -eq 0 ]; then
    for path in $process_files; do
        if [ "$path" != "$allowed_process_file" ]; then
            echo "plan audit failed: $foundation_process construction outside $allowed_process_file: $path" >&2
            failed=1
        fi
    done
elif [ "$process_status" -gt 1 ]; then
    echo "plan audit could not check $foundation_process construction" >&2
    echo "$process_files" >&2
    failed=1
fi

cg_event='CG''Event'
screen_capture_kit='ScreenCapture''Kit'
ax_ui_element='AXUI''Element'
handler_platform_apis="$cg_event|$screen_capture_kit|$ax_ui_element"
check_absent \
    "platform APIs inside MCP handler files" \
    "$handler_platform_apis" \
    Sources/SimulatorMCPCore/MCP/ToolHandlers.swift

if [ "$failed" -ne 0 ]; then
    exit 1
fi

echo "plan audit passed"
