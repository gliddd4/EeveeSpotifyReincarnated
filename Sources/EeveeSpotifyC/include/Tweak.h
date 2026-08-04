#import <Foundation/Foundation.h>
#import <mach-o/dyld.h>

NS_ASSUME_NONNULL_BEGIN

void EeveeSBInvokeSeekDouble(id target, SEL selector, double argument);

// Inline memory patch helper: NOP a 4-byte instruction at the given
// dyld-resolved runtime address inside the main Spotify image. Uses
// MSHookMemory so the write survives page-protection / code-signing.
// Returns YES on success, NO on failure (bad address / Spotify not loaded).
BOOL EeveeSBPatchInstruction(uintptr_t runtimeAddress);

NS_ASSUME_NONNULL_END
