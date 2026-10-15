import Foundation

/// Links that open an experience (PRD S3, S4).
///
/// - `cuardach://open?url=https%3A%2F%2Fexample.org%2Fhunt.arhunt`
/// - a plain `https://…/hunt.arhunt` URL (as scanned from a QR code)
///
/// Only HTTPS downloads are accepted: no plain HTTP, no file URLs, and no
/// local-network shortcuts disguised as other schemes.
public enum DeepLink: Equatable, Sendable {
    case download(URL)

    public static let scheme = "cuardach"

    public static func parse(_ url: URL) -> DeepLink? {
        if url.scheme?.lowercased() == scheme {
            guard url.host?.lowercased() == "open",
                  let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  let raw = comps.queryItems?.first(where: { $0.name == "url" })?.value,
                  let target = URL(string: raw) else { return nil }
            return isAllowedDownload(target) ? .download(target) : nil
        }
        return isAllowedDownload(url) ? .download(url) : nil
    }

    /// Parses text from a scanned QR code.
    public static func parse(qrPayload: String) -> DeepLink? {
        let trimmed = qrPayload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let u = URL(string: trimmed) else { return nil }
        return parse(u)
    }

    static func isAllowedDownload(_ u: URL) -> Bool {
        guard u.scheme?.lowercased() == "https", let host = u.host, !host.isEmpty, u.user == nil else { return false }
        return true
    }

    /// The link to encode in a QR code for a hosted bundle: the custom scheme
    /// opens the app directly when installed.
    public static func openLink(for download: URL) -> URL? {
        guard isAllowedDownload(download) else { return nil }
        var c = URLComponents()
        c.scheme = scheme
        c.host = "open"
        c.queryItems = [URLQueryItem(name: "url", value: download.absoluteString)]
        // URLComponents leaves ":" and "/" unescaped in query values; escape
        // them so the nested URL survives every QR reader intact.
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: ":/?&=#+")
        c.percentEncodedQuery = "url=" + (download.absoluteString.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")
        return c.url
    }
}
