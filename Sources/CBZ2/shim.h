// Umbrella header for the CBZ2 system-library target. bzlib.h is part of the
// macOS/iOS SDK; we only need the low-level one-shot decompression entry point
// (`BZ2_bzBuffToBuffDecompress`) for inflating bsdiff4's bz2 streams.
#include <bzlib.h>
