import Foundation
import MetagentCore

/// Privacy-forward product analytics for the native app. This intentionally
/// uses PostHog's capture endpoint instead of a client SDK: there is no
/// autocapture, session replay, identify call, feature-flag request, or hidden
/// event queue. Each event is constrained by `ProductAnalyticsEvent`.
@MainActor
final class ProductAnalytics {
    static let shared = ProductAnalytics()

    static let enabledPreferenceKey = "metagent.analytics.enabled.v1"
    static let installIDPreferenceKey = "metagent.analytics.install-id.v1"
    static let defaultEnabled = true

    private let projectToken = "phc_BEhfLjwSiN2vBoyEjs7gKDS5vowQX2v73bSrzcYEMso4"
    private let endpoint = URL(string: "https://us.i.posthog.com/i/v0/e/")!
    private let defaults: UserDefaults
    private let session: URLSession

    init(
        defaults: UserDefaults = .standard,
        session: URLSession? = nil
    ) {
        self.defaults = defaults
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpCookieStorage = nil
            configuration.urlCache = nil
            configuration.timeoutIntervalForRequest = 5
            configuration.timeoutIntervalForResource = 10
            self.session = URLSession(configuration: configuration)
        }
    }

    var isEnabled: Bool {
        guard defaults.object(forKey: Self.enabledPreferenceKey) != nil else {
            return Self.defaultEnabled
        }
        return defaults.bool(forKey: Self.enabledPreferenceKey)
    }

    func setEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: Self.enabledPreferenceKey)
    }

    func capture(_ event: ProductAnalyticsEvent) {
        guard isEnabled else { return }

        var properties: [String: Any] = event.properties
        properties["$process_person_profile"] = false
        properties["$geoip_disable"] = true
        properties["app_version"] = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "unknown"
        properties["app_build"] = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleVersion"
        ) as? String ?? "unknown"
        properties["app_channel"] = Bundle.main.bundleIdentifier?.hasSuffix(".dev") == true
            ? "dev"
            : "release"

        let payload: [String: Any] = [
            "api_key": projectToken,
            "event": event.name,
            "distinct_id": installID,
            "properties": properties,
        ]
        guard JSONSerialization.isValidJSONObject(payload),
              let body = try? JSONSerialization.data(withJSONObject: payload)
        else { return }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        session.dataTask(with: request).resume()
    }

    private var installID: String {
        if let stored = defaults.string(forKey: Self.installIDPreferenceKey),
           UUID(uuidString: stored) != nil
        {
            return stored
        }
        let generated = UUID().uuidString.lowercased()
        defaults.set(generated, forKey: Self.installIDPreferenceKey)
        return generated
    }
}
