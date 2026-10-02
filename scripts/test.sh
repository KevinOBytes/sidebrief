#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
echo "=== Running Sidebrief Test Suite ==="

# 1. Native Swift Tests
echo "--> Running Swift Core, Audio, STT, and Storage Tests..."
cd "$ROOT_DIR"
swift test

# 2. Backend & Neon PostgreSQL Tests
echo "--> Running Backend API & Neon PostgreSQL Integration Tests..."
cd "$ROOT_DIR/backend"
npm test

echo "=== All Tests Passed Successfully ==="
