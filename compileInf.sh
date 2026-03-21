#!/bin/bash
zig build -Doptimize=ReleaseFast
cd zig-out/bin
./Evolution 0
