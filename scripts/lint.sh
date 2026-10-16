#!/usr/bin/env bash
# Checks formatting and lint rules without changing files. `make format` fixes.
set -euo pipefail
cd "$(dirname "$0")/.."

swift format lint --strict --recursive --parallel App Packages/MirrorCore/Sources Packages/MirrorCore/Tests Packages/MirrorCore/Package.swift
mise exec -- actionlint
