#!/usr/bin/env sh
# Runs the openXC7 flow in Docker. Usage: ./build.sh [make target]
exec docker run --rm -v "$(cd "$(dirname "$0")" && pwd):/work" -w /work "${IMAGE:-openxc7-2:latest}" make "${1:-all}"

