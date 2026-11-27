#pragma once

// Native host filesystem and process access for the local engine, mirroring what
// the phone binding does: a linked N-API module the engine can require, with the
// work done in C++ rather than in the guest.
//
// This exists because the guest cannot reach the host filesystem: iSH resolves
// paths through its own fakefs, and mounting the host root into it hung the engine
// start on device. The app itself already holds the entitlements that make host
// paths readable (no-sandbox), so the shortest reliable path is to let the engine
// call the host directly.
void RegisterHostFsBinding();
