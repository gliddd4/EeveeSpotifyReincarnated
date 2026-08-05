import Foundation

// Shared by SPTDataLoaderServiceHook and HttpClientURLSessionHook. Lyrics is
// kept in each caller because its async fetch doesn't fit a sync transform.
enum SpotifyResponsePatcher {

    // Patched customize body, replayed for 304s and post-startup re-fetches
    // so ad flags can't re-enable mid-session. Touched from two hook classes on
    // URLSession's concurrent delegate queues — all access is lock-guarded.
    private static let lock = NSLock()
    private static var _cachedCustomizeData: Data?
    // Keyed by task identity (ObjectIdentifier), not taskIdentifier: identifiers
    // are only unique per URLSession and both hooked sessions run concurrently,
    // so an identically-numbered task in the other session could suppress this
    // task's completion and leave its consumer waiting forever.
    private static var _handledCustomizeTasks = Set<ObjectIdentifier>()

    static var cachedCustomizeData: Data? {
        get { lock.lock(); defer { lock.unlock() }; return _cachedCustomizeData }
        set { lock.lock(); defer { lock.unlock() }; _cachedCustomizeData = newValue }
    }

    static func markCustomizeTaskHandled(_ task: URLSessionTask) {
        lock.lock(); defer { lock.unlock() }
        _handledCustomizeTasks.insert(ObjectIdentifier(task))
    }

    // Returns true exactly once per task (the task that synthesized the replay).
    static func consumeCustomizeTask(_ task: URLSessionTask) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return _handledCustomizeTasks.remove(ObjectIdentifier(task)) != nil
    }

    // ── START OF AI GENERATED CODE ──
    private static var _handledLyricsTasks = Set<ObjectIdentifier>()

    static func markLyricsTaskHandled(_ task: URLSessionTask) {
        lock.lock(); defer { lock.unlock() }
        _handledLyricsTasks.insert(ObjectIdentifier(task))
    }

    // Returns true exactly once per task — prevents didCompleteWithError from
    // re-delivering lyrics that didReceiveResponse already fully delivered.
    static func consumeLyricsTask(_ task: URLSessionTask) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return _handledLyricsTasks.remove(ObjectIdentifier(task)) != nil
    }
    // ── END OF AI GENERATED CODE ──

    static func shouldBlock(_ url: URL) -> Bool {
        let elapsed = Date().timeIntervalSince(tweakInitTime)
        let path = url.path.lowercased()

        if url.isDeleteToken || url.isSessionInvalidation
            || path.contains("session/purge") || path.contains("token/revoke")
            || url.isAdRelated {
            return true
        }
        if path.contains("/dac/view/v1/") { return true }
        if path.contains("/esperanto/") && (path.contains("ad") || path.contains("slot")) {
            return true
        }

        // 30s grace: signup/public is part of fresh-login; blocking pre-30s
        // breaks first-launch.
        if elapsed > 30 {
            return url.isAccountValidate || url.isOndemandSelector
                || url.isTrialsFacade || url.isPremiumMarketing || url.isPendragonFetchMessageList
                || url.isPushkaTokens
                || url.path.contains("signup/public") || url.path.contains("apresolve")
                || url.path.contains("pses/screenconfig")
                || url.path.contains("v1/customize")
        }
        return false
    }

    static func shouldModify(_ url: URL) -> Bool {
        let shouldPatchPremium = BasePremiumPatchingGroup.isActive || PremiumBootstrapGroup.isActive
        let shouldReplaceLyrics = BaseLyricsGroup.isActive
        let isDAC = url.path.lowercased().contains("/dac/view/v1/")

        // ── START OF AI GENERATED CODE ──
        if url.isLyrics {
            writeDebugLog("[Patcher] shouldModify lyrics: shouldReplaceLyrics=\(shouldReplaceLyrics) path=\(url.path)")
        }
        // ── END OF AI GENERATED CODE ──

        return (shouldReplaceLyrics && url.isLyrics)
            || (shouldPatchPremium && (
                url.isBootstrap || url.isCustomize ||
                url.isPremiumPlanRow || url.isPremiumBadge || url.isPlanOverview ||
                isDAC
            ))
            || BrowsitaSectionStripper.shouldHandle(url)
    }

    static func blockedResponseData(for url: URL) -> Data {
        if url.isAccountValidate {
            return #"{"status":1,"country":"US","is_country_launched":true}"#.data(using: .utf8)!
        }
        if url.isTrialsFacade {
            return #"{"result":"NOT_ELIGIBLE"}"#.data(using: .utf8)!
        }
        if url.isPremiumMarketing {
            return #"{}"#.data(using: .utf8)!
        }
        if url.isSessionInvalidation
            || url.path.contains("session/purge")
            || url.path.contains("token/revoke")
            || url.path.contains("signup/public")
            || url.path.contains("apresolve") {
            // Logout daemons parse the body; synthetic OK keeps them off the
            // actual logout codepath.
            return #"{"status":"OK"}"#.data(using: .utf8)!
        }
        if url.path.contains("pses/screenconfig") {
            return #"{}"#.data(using: .utf8)!
        }
        if url.path.contains("v1/customize"), let cached = cachedCustomizeData {
            return cached
        }
        return Data()
    }

    enum PatchTag: String {
        case bootstrap   = "bootstrap"
        case customize   = "customize"
        case planRow     = "PremiumPlanRow"
        case planBadge   = "YourPremiumBadge"
        case planOverview = "PlanOverview"
        case dacEmpty    = "dac"
        case casitaStrip = "casitaStrip"
    }

    struct PatchResult {
        let data: Data
        let tag: PatchTag
    }

    static func patch(url: URL, buffer: Data) throws -> PatchResult? {
        if url.isPremiumPlanRow {
            return PatchResult(
                data: try getPremiumPlanRowData(
                    originalPremiumPlanRow: try PremiumPlanRow(serializedBytes: buffer)
                ),
                tag: .planRow
            )
        }
        if url.isPremiumBadge {
            return PatchResult(data: try getPremiumPlanBadge(), tag: .planBadge)
        }
        if url.isBootstrap {
            var msg = try BootstrapMessage(serializedBytes: buffer)
            UserDefaults.hasPatchedBootstrap = true
            if UserDefaults.patchType == .requests {
                modifyRemoteConfiguration(&msg.ucsResponse)
            }
            return PatchResult(data: try msg.serializedBytes(), tag: .bootstrap)
        }
        if url.isCustomize {
            var msg = try CustomizeMessage(serializedBytes: buffer)
            modifyRemoteConfiguration(&msg.response)
            let data = try msg.serializedData()
            cachedCustomizeData = data
            return PatchResult(data: data, tag: .customize)
        }
        if url.isPlanOverview {
            return PatchResult(data: try getPlanOverviewData(), tag: .planOverview)
        }
        if url.path.lowercased().contains("/dac/view/v1/") {
            // Empty body = "no ad to render" to the DAC consumer.
            return PatchResult(data: Data(), tag: .dacEmpty)
        }
        if BrowsitaSectionStripper.shouldHandle(url) {
            if let stripped = BrowsitaSectionStripper.strip(buffer, url: url) {
                return PatchResult(data: stripped, tag: .casitaStrip)
            }
            return nil
        }
        return nil
    }
}
