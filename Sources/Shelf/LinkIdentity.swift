import Foundation

enum LinkIdentity {
    static func standalone(_ text: String) -> URL? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.utf8.count <= 8192, value.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              let url = URL(string: value), normalized(url) != nil else { return nil }
        return url
    }
    static func youtubeID(_ url: URL) -> String? {
        guard let host = url.host?.lowercased() else { return nil }
        let pieces = url.path.split(separator: "/").map(String.init)
        let candidate: String?
        if host == "youtu.be" || host == "www.youtu.be" { candidate = pieces.first }
        else if ["youtube.com","www.youtube.com","m.youtube.com","music.youtube.com"].contains(host) {
            if ["shorts","embed","live"].contains(pieces.first ?? ""), pieces.count > 1 { candidate = pieces[1] }
            else { candidate = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "v" }?.value }
        } else { candidate = nil }
        guard let candidate, candidate.count == 11, candidate.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-").contains($0) }) else { return nil }
        return candidate
    }
    static func normalized(_ url: URL) -> String? {
        guard var c = URLComponents(url: url, resolvingAgainstBaseURL: false),
              ["http","https"].contains(c.scheme?.lowercased() ?? ""), let host = c.host, !host.isEmpty else { return nil }
        c.scheme = c.scheme?.lowercased(); c.host = host.lowercased()
        if (c.scheme == "https" && c.port == 443) || (c.scheme == "http" && c.port == 80) { c.port = nil }
        var parameters = (c.queryItems ?? []).filter { !$0.name.lowercased().hasPrefix("utm_") && !["fbclid","gclid"].contains($0.name.lowercased()) }
        if let id = youtubeID(url) {
            c.scheme = "https"; c.host = "www.youtube.com"; c.path = "/watch"; c.port = nil
            parameters.removeAll { $0.name == "v" || $0.name == "si" }; parameters.insert(URLQueryItem(name: "v", value: id), at: 0)
        }
        if c.path.isEmpty { c.path = "/" }
        c.queryItems = parameters.isEmpty ? nil : parameters
        return c.url?.absoluteString
    }
    static func mayFetchMetadata(_ url: URL) -> Bool {
        PublicLinkDestination(url) != nil
    }
}

/// Links that carry a credential or a single-use value, or that act when they
/// are opened. Capture keeps none that carry a credential, and previews never
/// request any of them.
enum LinkSensitivity {
    /// Parameter names for credentials, compared with separators and case
    /// removed; these also match inside a longer name.
    private static let secretStems = ["token", "secret", "passw", "passcode", "passphrase", "nonce", "magic", "signature",
                                      "credential", "bearer", "apikey", "accesskey", "privatekey", "secretkey", "sessionid", "sessid",
                                      "authoriz", "authent", "oauth", "xamz", "xgoog"]
    /// Short names that match only as a whole word of the parameter name.
    private static let secretWords: Set<String> = ["sig", "auth", "otp", "totp", "pwd", "jwt", "keypairid", "hmac"]
    /// Common words that name a secret only beside one of the qualifiers below,
    /// as in auth_code or session_key, or when the value reads as random.
    private static let genericWords: Set<String> = ["key", "code", "session", "ticket", "sid"]
    private static let genericQualifiers: Set<String> = ["access", "api", "app", "client", "confirm", "confirmation", "license", "login", "master",
                                                         "private", "recovery", "reset", "secret", "security", "service", "session", "signin",
                                                         "signing", "verification", "verify"]
    /// Parameters of single-use or personal requests. Not credentials on their
    /// own, so only previews refuse them.
    private static let actionParameterStems = ["invite", "invitation", "reset", "confirm", "verif", "unsub"]
    private static let actionParameterWords: Set<String> = ["state", "policy"]
    /// Path words for pages that sign in, confirm, reset or unsubscribe on a visit.
    private static let actionStems = ["reset", "verif", "confirm", "recover", "magic", "unsub", "invit", "activat", "optout"]
    private static let actionWords: Set<String> = ["password", "passwd", "email", "account", "link", "token", "auth", "login", "signin", "opt", "out", "user"]
    /// File name endings that are not words of a page name.
    private static let pageExtensions: Set<String> = ["php", "html", "htm", "asp", "aspx", "jsp", "cgi", "do", "action"]
    /// Path words after which a random-looking segment is a key, as in
    /// /webhooks/<id>/<token> or /login/<token>.
    private static let pathSecretStems = ["hook", "webhook", "token", "secret", "credential", "apikey", "passw", "signin", "magic",
                                          "reset", "verif", "confirm", "invit", "activat", "recover", "unsub"]
    private static let pathSecretWords: Set<String> = ["auth", "oauth", "oauth2", "login", "logon", "sso", "session", "sessions", "key", "keys"]

    /// The words of a name: split at separators and lower-to-upper case changes.
    static func words(_ name: String) -> [String] {
        var result = [String](), current = ""
        var previousLower = false
        for character in name {
            guard character.isLetter || character.isNumber else {
                if !current.isEmpty { result.append(current.lowercased()); current = "" }
                previousLower = false; continue
            }
            if character.isUppercase && previousLower && !current.isEmpty { result.append(current.lowercased()); current = "" }
            current.append(character); previousLower = character.isLowercase || character.isNumber
        }
        if !current.isEmpty { result.append(current.lowercased()) }
        return result
    }
    /// A name that is a credential whatever its value.
    static func isSecretName(_ name: String) -> Bool {
        let parts = words(name), compact = parts.joined()
        return parts.contains(where: secretWords.contains) || secretStems.contains(where: compact.contains)
            || (parts.contains(where: genericWords.contains) && parts.contains { genericQualifiers.contains($0) && !genericWords.contains($0) }
                || parts.filter(genericWords.contains).count > 1)
    }
    /// A credential by name, or a common name such as code or key whose value
    /// reads as random.
    static func isSecretParameter(_ name: String, _ value: String) -> Bool {
        isSecretName(name) || isTokenShaped(value)
            || (words(name).contains(where: genericWords.contains) && isRandomLooking(value, length: 16, distinct: 8))
    }
    /// header.payload.signature, each part base64url, the header a JSON object.
    static func isTokenShaped(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        let alphabet = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_=")
        return parts.count == 3 && parts[0].hasPrefix("eyJ") && parts.allSatisfy { !$0.isEmpty && $0.unicodeScalars.allSatisfy(alphabet.contains) }
    }
    /// A long value of letters and digits that reads as random, as access keys,
    /// signatures and one-time codes do.
    static func isRandomLooking(_ value: String, length: Int = 24, distinct: Int = 12) -> Bool {
        let alphabet = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~+/=%")
        guard value.count >= length, value.unicodeScalars.allSatisfy(alphabet.contains),
              value.contains(where: \.isNumber), value.contains(where: \.isLetter) else { return false }
        return Set(value).count >= distinct
    }
    /// name=value pairs, also when they are separated by semicolons.
    private static func items(_ encoded: String?) -> [URLQueryItem] {
        guard let encoded, !encoded.isEmpty else { return [] }
        var parsed = URLComponents(); parsed.percentEncodedQuery = encoded.replacingOccurrences(of: ";", with: "&")
        return parsed.queryItems ?? []
    }
    /// The query and, for links that carry values after the #, the fragment.
    private static func parameters(_ c: URLComponents) -> [URLQueryItem] {
        items(c.percentEncodedQuery) + (c.fragment?.contains("=") == true ? items(c.percentEncodedFragment) : [])
    }
    private static func isPathSecretWord(_ word: String) -> Bool {
        pathSecretWords.contains(word) || pathSecretStems.contains(where: word.hasPrefix)
    }
    /// A signed token, a secret ;name=value parameter, an id:key pair as in
    /// /bot<id>:<key>, or a random-looking segment after a word such as
    /// webhooks or login. Ordinary document and commit IDs are not keys.
    static func pathCarriesSecret(_ c: URLComponents) -> Bool {
        let subdomain = c.host?.split(separator: ".").first.map { words(String($0)) } ?? []
        var keyed = subdomain.contains { $0.hasPrefix("hook") || $0.hasPrefix("webhook") }
        for segment in c.path.split(separator: "/") {
            let pieces = segment.split(separator: ";", omittingEmptySubsequences: false).map(String.init)
            if pieces.dropFirst().contains(where: { piece in
                let pair = piece.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
                return isSecretParameter(pair[0], pair.count > 1 ? pair[1] : "")
            }) { return true }
            let name = pieces[0]
            if isTokenShaped(name) || (keyed && isRandomLooking(name)) { return true }
            let pair = name.split(separator: ":", maxSplits: 1).map(String.init)
            if pair.count == 2, pair[0].contains(where: \.isNumber), pair[0].allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }),
               isRandomLooking(pair[1]) { return true }
            if words(name).contains(where: isPathSecretWord) { keyed = true }
        }
        return false
    }
    /// A user name or password, a secret parameter or path segment, or a
    /// signed token anywhere in the path or a value.
    static func carriesCredentials(_ c: URLComponents) -> Bool {
        if c.user != nil || c.password != nil { return true }
        return parameters(c).contains { isSecretParameter($0.name, $0.value ?? "") } || pathCarriesSecret(c)
    }
    static func carriesCredentials(_ url: URL) -> Bool {
        guard let c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return true }
        return carriesCredentials(c)
    }
    /// A short page name with a word such as reset, verify or confirm, as in
    /// /resetpassword.php or /verify-email-address. Longer titles that only
    /// mention one, such as /how-to-reset-your-router, are not.
    static func isActionSegment(_ segment: String) -> Bool {
        func isAction(_ word: String) -> Bool {
            actionStems.contains(where: word.hasPrefix)
                || actionWords.contains { word.hasPrefix($0) && actionStems.contains(where: word.dropFirst($0.count).hasPrefix) }
        }
        let parts = words(segment).filter { !pageExtensions.contains($0) && !$0.allSatisfy(\.isNumber) }
        guard parts.contains(where: isAction) else { return false }
        return parts.count <= 3 || parts.allSatisfy { actionWords.contains($0) || isAction($0) }
    }
    /// Also refuses single-use pages by their path, common names such as code
    /// on their own, and values that read as random.
    static func mayRequest(_ c: URLComponents) -> Bool {
        guard !carriesCredentials(c) else { return false }
        let actionPath = c.path.split(separator: "/").contains { isActionSegment(String($0)) }
        return !actionPath && !parameters(c).contains { item in
            let parts = words(item.name), compact = parts.joined()
            return parts.contains(where: actionParameterWords.contains) || actionParameterStems.contains(where: compact.contains)
                || (!parts.isEmpty && parts.allSatisfy(genericWords.contains)) || isRandomLooking(item.value ?? "")
        }
    }
}
