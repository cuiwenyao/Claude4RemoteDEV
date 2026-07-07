#!/bin/bash
# resync.sh — rebuild the Mutagen sync scope from the current <MIRROR_ROOT>/.gitignore.
# Run this after editing .gitignore.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "$HERE/sync-start.sh" --force
