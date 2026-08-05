import UIKit
import Combine

struct AnonymousTokenHelper {
    private static let apiUrl = "https://apic.musixmatch.com"

    private static func fetchToken(appId: String) throws -> String {
        guard let encodedAppId = appId.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "\(apiUrl)/ws/1.1/token.get?app_id=\(encodedAppId)") else {
            throw AnonymousTokenError.invalidResponse
        }

        let semaphore = DispatchSemaphore(value: 0)
        var responseData: Data?
        var responseError: Error?

        var request = URLRequest(url: url)
        request.timeoutInterval = 10

        let task = URLSession.shared.dataTask(with: request) { data, _, error in
            responseData = data
            responseError = error
            semaphore.signal()
        }
        task.resume()
        // Bound the wait so a hung network can't leave the settings UI stuck in
        // isRequestingMusixmatchToken for minutes (up to 3 sequential 60s tries).
        if semaphore.wait(timeout: .now() + 15) == .timedOut {
            task.cancel()
            throw AnonymousTokenError.invalidResponse
        }

        if let error = responseError {
            throw error
        }

        guard
            let data = responseData,
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let message = json["message"] as? [String: Any],
            let body = message["body"] as? [String: Any],
            let userToken = body["user_token"] as? String,
            !userToken.isEmpty,
            userToken != "UpgradeRequired"
        else {
            throw AnonymousTokenError.invalidResponse
        }

        return userToken
    }

    static func requestAnonymousMusixmatchToken() -> AnyPublisher<String, Error> {
        let appIds = [
            UIDevice.current.musixmatchAppId,
            UIDevice.current.isIpad ? "mac-ios-v2.0" : "mac-ios-ipad-v1.0",
            "web-desktop-app-v1.0"
        ]

        return Deferred {
            Future<String, Error> { promise in
                DispatchQueue.global(qos: .userInitiated).async {
                    for appId in appIds {
                        if let token = try? fetchToken(appId: appId) {
                            promise(.success(token))
                            return
                        }
                    }
                    promise(.failure(AnonymousTokenError.invalidResponse))
                }
            }
        }
        .eraseToAnyPublisher()
    }
}
