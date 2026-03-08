#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "=== Deploying OTS ==="

# Build
echo "Building..."
docker compose build

# Deploy
echo "Starting services..."
docker compose up -d

echo "=== OTS deployed successfully ==="
