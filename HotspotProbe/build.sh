#!/bin/zsh
set -eu
cd -- "${0:A:h}"
xcrun clang -fobjc-arc -Wall -Wextra -framework Foundation -framework CoreWLAN main.m -o hotspot-probe
./hotspot-probe --help
