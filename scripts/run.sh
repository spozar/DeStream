#!/bin/zsh
# Build the macOS app and launch it.
set -e
cd "$(dirname "$0")/.."
scripts/build.sh app mac
open .build/dd-app/Build/Products/Debug/DeStream.app
