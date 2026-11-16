#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
"$project_dir/scripts/build.sh"
open "$project_dir/dist/Codex Pace.app" --args "$@"
