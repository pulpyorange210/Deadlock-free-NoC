#!/bin/bash
export PDK_ROOT=/pdk
echo "PDK_ROOT=$PDK_ROOT"
if [ -d "$PDK_ROOT/sky130A" ]; then
    echo "SKY130A_ALREADY_PRESENT"
    exit 0
fi
echo "--- pinned open_pdks version in image ---"
grep -A3 -i 'open_pdks' /openlane/dependencies/tool_metadata.yml 2>/dev/null | head -8
VER=$(grep -A3 -i 'name: *"\?open_pdks' /openlane/dependencies/tool_metadata.yml 2>/dev/null \
      | grep -i 'commit' | head -1 | sed 's/.*: *//' | tr -d '"'"'"' ')
echo "resolved VER='$VER'"
if [ -z "$VER" ]; then
    echo "--- falling back to newest remote ---"
    VER=$(volare ls-remote --pdk sky130 2>/dev/null | grep -Eo '[0-9a-f]{40}' | head -1)
    echo "remote VER='$VER'"
fi
if [ -z "$VER" ]; then echo "NO_VERSION_RESOLVED"; exit 2; fi
volare enable --pdk sky130 "$VER"
echo "--- result ---"
ls "$PDK_ROOT"
ls -d "$PDK_ROOT/sky130A" && echo "SKY130A_OK" || echo "SKY130A_MISSING"
