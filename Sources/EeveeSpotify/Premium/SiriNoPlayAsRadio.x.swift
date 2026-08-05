import Orion
import Intents

class INMediaItemHook: ClassHook<INMediaItem> {
    typealias Group = PremiumUIHooksGroup
    
    func identifier() -> String {
        let identifier = orig.identifier()
        
        // Malformed identifiers (fewer than 3 colon components, non-base64 body,
        // non-JSON payload, or missing context/url keys) must not crash Siri —
        // bail out and pass the original through untouched.
        guard identifier.contains("play-command") else {
            return identifier
        }
        
        let components = identifier.components(separatedBy: ":")
        guard components.count > 2,
              let jsonData = Data(base64Encoded: components[2]),
              let jsonObject = try? JSONSerialization.jsonObject(with: jsonData),
              var json = jsonObject as? [String: Any],
              let feedbackDetails = json["feedback_details"] as? [String: Any],
              feedbackDetails["restriction"] as? String == "play-as-radio",
              var context = json["context"] as? [String: Any],
              let urlString = context["url"] as? String else {
            return identifier
        }
        
        context["url"] = urlString.removeMatches(":station")
        json["context"] = context
        
        guard let patchedData = try? JSONSerialization.data(withJSONObject: json) else {
            return identifier
        }
        return "spotify:play-command:\(patchedData.base64EncodedString())"
    }
}
