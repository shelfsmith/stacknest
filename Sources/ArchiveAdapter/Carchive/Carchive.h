#ifndef CARCHIVE_H
#define CARCHIVE_H

// Apple's macOS SDK ships the libarchive dylib and a .tbd stub, but does NOT
// ship archive.h — so compilation needs headers from somewhere else, while
// the linker still targets the SDK's universal libarchive.tbd (declared in
// module.modulemap) so Universal (arm64 + x86_64) builds work on any Mac.
//
// G28: prefer headers fetched by Scripts/fetch-libarchive-headers.sh, which
// match the exact version of Apple's runtime dylib (avoids header/runtime
// version drift — see Tests/ArchiveAdapterTests/LibarchiveVersionTests.swift).
// These are gitignored; a machine that hasn't run the script falls back to
// the pre-existing Homebrew/system search order unchanged.
#if __has_include("vendor/archive.h")
  #include "vendor/archive.h"
  #include "vendor/archive_entry.h"
#elif __has_include("/opt/homebrew/opt/libarchive/include/archive.h")
  // Apple Silicon Homebrew prefix
  #include "/opt/homebrew/opt/libarchive/include/archive.h"
  #include "/opt/homebrew/opt/libarchive/include/archive_entry.h"
#elif __has_include("/usr/local/opt/libarchive/include/archive.h")
  // Intel Homebrew prefix
  #include "/usr/local/opt/libarchive/include/archive.h"
  #include "/usr/local/opt/libarchive/include/archive_entry.h"
#else
  // Fallback (e.g. CI with system libarchive headers)
  #include <archive.h>
  #include <archive_entry.h>
#endif

#endif /* CARCHIVE_H */
