#!/bin/bash
echo "--- where is flow.tcl ---"
readlink -f "$(which flow.tcl)"
F=$(readlink -f "$(which flow.tcl)")
D=$(dirname "$F")
echo "--- version check source ---"
grep -rn "does not match the version" "$D" 2>/dev/null | head -5
echo "--- bypass flags ---"
grep -rn "ignore_mismatches\|PDK_VERSION_CHECK\|skip_pdk" "$D" 2>/dev/null | head -10
