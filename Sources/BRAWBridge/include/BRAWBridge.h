#ifndef CZ_BRAW_BRIDGE_H
#define CZ_BRAW_BRIDGE_H

#include <CoreGraphics/CoreGraphics.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

/// True when a Blackmagic RAW decoder (BlackmagicRawAPI.framework from Blackmagic RAW Player,
/// DaVinci Resolve or the SDK) is installed and could be loaded.
bool CZBRAWIsAvailable(void);

/// Decodes the first frame of a .braw clip at a reduced resolution (at least `maxDimension`
/// pixels wide where possible) and returns it as a +1 retained CGImage, or NULL on failure.
CGImageRef _Nullable CZBRAWCreateThumbnail(const char * _Nonnull path, int maxDimension) CF_RETURNS_RETAINED;

#ifdef __cplusplus
}
#endif

#endif
