// SPDX-License-Identifier: CC0-1.0
// minimp3 implementation translation unit. The dependency itself is pinned in
// build.zig.zon; keeping the implementation macro here avoids compiling it in
// every Zig @cImport translation unit.

#define MINIMP3_ONLY_MP3
#define MINIMP3_IMPLEMENTATION
#include "minimp3.h"
