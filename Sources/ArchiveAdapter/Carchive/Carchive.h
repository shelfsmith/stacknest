#ifndef CARCHIVE_H
#define CARCHIVE_H

// Use Homebrew headers for compilation (archive.h is not in Apple SDK),
// but let the linker use the SDK's universal libarchive.tbd so that
// Universal (arm64 + x86_64) builds work on any Mac.
#if __has_include("/opt/homebrew/opt/libarchive/include/archive.h")
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
