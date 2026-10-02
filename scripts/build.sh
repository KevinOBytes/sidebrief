#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
echo "=== Building Sidebrief ==="
echo "Project root: $ROOT_DIR"

# 1. Build Backend API
echo "--> Compiling Backend TypeScript..."
cd "$ROOT_DIR/backend"
npm run build

# 2. Build Native Swift Targets
echo "--> Compiling Native macOS Swift Binaries (Release)..."
cd "$ROOT_DIR"
swift build -c release

echo "=== Build Completed Successfully ==="
