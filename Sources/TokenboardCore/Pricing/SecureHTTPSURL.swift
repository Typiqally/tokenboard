import Foundation

enum SecureHTTPSURL {
    static func components(_ value: String) -> URLComponents? {
        guard let components = URLComponents(string: value),
              components.scheme?.lowercased() == "https",
              components.host != nil,
              components.user == nil,
              components.password == nil,
              components.port == nil,
              components.url != nil else {
            return nil
        }
        return components
    }

    static func parse(_ value: String) -> URL? {
        components(value)?.url
    }
}
