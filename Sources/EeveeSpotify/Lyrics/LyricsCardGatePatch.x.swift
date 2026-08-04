import Orion
import Foundation
import MachO.dyld
import EeveeSpotifyC

// ── START OF AI GENERATED CODE ──
// The actual lyrics-card gate on 9.1.68:
//
//   LyricsUIServiceImplementation.registerScrollProviderIn:  (IMP 0x10772ad94)
//       → bl 0x1034f57c8 (shared lyrics scroll-card registration helper)
//           → casts the lyrics provider to SPTNowPlayingScrollCardProvidable
//           → invokes a Swift witness method returning Bool in w0
//           → tbz w20, #0x0, exit  (at 0x1034f584c)
//
// If that Bool is false (the witness says "not available for this track"),
// the function jumps straight to the epilogue WITHOUT calling
// NowPlayingScrollDataSourceImplementation registerProvider:, so the
// lyrics scroll card is silently dropped. For local files the witness
// returns false — the lyrics card never appears even though our lyrics
// delivery pipeline works end-to-end.
//
// Fix: NOP the single `tbz` instruction at 0x1034f584c so registration
// always proceeds. Two-byte surgical patch. The provider itself still
// decides whether to render a card based on loaded lyrics data, but
// registration can no longer be skipped up-front.

struct V91LyricsCardGatePatchGroup: HookGroup {}

private enum LyricsCardGateAddress {
    // __TEXT segment vmaddr in the decrypted Spotify binary.
    static let textSegmentVmaddr: UInt64 = 0x100000000
    // File offset of the `tbz w20, #0x0, exit` instruction within
    // __TEXT,__text (verified by reading 4 bytes at 0x34f584c → 0x360004f4
    // which decodes as `tbz w20, #0, 0x1034f58e8`).
    static let tbzFileOffset: UInt = 0x34f584c
    // The linked (pre-slide) runtime address of that instruction.
    static let tbzLinkedAddress: UInt64 = textSegmentVmaddr + UInt64(tbzFileOffset)
}

// Resolve the runtime load address of the main Spotify executable image.
// Iterate dyld images and match by name — safer than trusting index 0,
// which can be wrong if injection reorders images.
private func spotifyMainImageBase() -> UInt64 {
    var idx: UInt32 = 0
    while let header = _dyld_get_image_header(idx) {
        if let nameC = _dyld_get_image_name(idx) {
            let name = String(cString: nameC)
            if name.hasSuffix("/Spotify") {
                return UInt64(UInt(bitPattern: header))
            }
        }
        idx &+= 1
    }
    // Fallback to image 0 if name-based lookup fails.
    guard let header = _dyld_get_image_header(0) else { return 0 }
    return UInt64(UInt(bitPattern: header))
}

// Patch the gate instruction. Must run AFTER Spotify's __TEXT segment is
// already mapped — safest in the tweak init flow inside Tweak.x.swift
// (well past constructor time). Idempotent.
func patchLyricsCardGate() {
    let mainBase = spotifyMainImageBase()
    guard mainBase != 0 else {
        writeDebugLog("[LyricsGatePatch] Could not resolve Spotify main image base")
        return
    }

    // The image slide is mainBase - linked-vmaddr (slide applies uniformly to
    // every segment offset). Runtime address of the gate = linked + slide.
    let slide = mainBase &- LyricsCardGateAddress.textSegmentVmaddr
    let runtimeAddress = LyricsCardGateAddress.tbzLinkedAddress &+ slide

    writeDebugLog("[LyricsGatePatch] mainBase=0x\(String(mainBase, radix: 16)) "
                + "slide=0x\(String(slide, radix: 16)) "
                + "target=0x\(String(runtimeAddress, radix: 16))")

    // Verify the byte at the target is the expected tbz instruction.
    // If the build-time IPA patch already NOP'd it, we're done.
    let expectedTbz: UInt32 = 0x360004f4
    let expectedNop: UInt32 = 0xD503201F
    let actual = unsafeBitLoad32(at: runtimeAddress)
    if actual == expectedNop {
        writeDebugLog("[LyricsGatePatch] Already NOP-patched (build-time), nothing to do")
        return
    }
    if actual != expectedTbz {
        writeDebugLog("[LyricsGatePatch] WARNING: byte at target is "
                    + "0x\(String(actual, radix: 16)), expected 0x\(String(expectedTbz, radix: 16)) "
                    + "— Spotify build may differ, skipping patch")
        return
    }

    let success = EeveeSBPatchInstruction(UInt(runtimeAddress))
    if success {
        writeDebugLog("[LyricsGatePatch] Runtime NOP applied at 0x\(String(runtimeAddress, radix: 16))")
    } else {
        writeDebugLog("[LyricsGatePatch] Runtime NOP FAILED (vm_protect denied by PPL) — build-time patch must handle it")
    }
}

@inline(__always)
private func unsafeBitLoad32(at address: UInt64) -> UInt32 {
    let ptr = UnsafeRawPointer(bitPattern: UInt(address))
    guard let p = ptr else { return 0 }
    return p.load(as: UInt32.self)
}
// ── END OF AI GENERATED CODE ──
