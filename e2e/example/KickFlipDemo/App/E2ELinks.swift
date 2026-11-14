#if DEBUG
import Foundation

/// E2E only (DEBUG builds): the two custom-scheme URLs the e2e run opens, parsed. Foundation only.
enum E2ELinks {

    /// `kickflip://e2e-universal-link?url=<https link>` → the https link, handed to the SDK exactly
    /// like a Universal Link (the unsigned e2e build has no Associated Domains). Only an `https` URL
    /// with a host is forwarded: anything else (another `kickflip://` URL, `http`, a missing or
    /// empty `url`) returns `nil`, so the forwarder can never loop into itself or into `e2e-track`.
    static func universalLink(_ url: URL) -> URL? {
        guard url.scheme == "kickflip", url.host == "e2e-universal-link",
              let value = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "url" })?.value,
              let link = URL(string: value), link.scheme == "https",
              let host = link.host, !host.isEmpty else { return nil }
        return link
    }

    /// One event a `kickflip://e2e-track` URL asks for.
    struct Event: Equatable {
        let name: String
        let value: Double?
        let currency: String?
    }

    /// `kickflip://e2e-track?event=<name>[&value=<major>][&currency=<ISO>][&event=…]` → the events,
    /// in order. Each `event=` starts a new event; the `value=` / `currency=` after it belong to it.
    /// `nil` when the URL is not an e2e-track URL, has no event, has an empty event name, or a value
    /// that is not a finite number (a typo must fail the flow, not send an event without its value).
    static func trackRequest(_ url: URL) -> [Event]? {
        guard url.scheme == "kickflip", url.host == "e2e-track",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return nil }
        var events: [Event] = []
        var name: String?, value: Double?, currency: String?
        func flush() { if let name { events.append(Event(name: name, value: value, currency: currency)) } }
        for item in items {
            switch item.name {
            case "event":
                flush()
                guard let v = item.value, !v.isEmpty else { return nil }
                name = v; value = nil; currency = nil
            case "value":
                guard name != nil, let raw = item.value, let v = Double(raw), v.isFinite else { return nil }
                value = v
            case "currency":
                guard name != nil, let v = item.value, !v.isEmpty else { return nil }
                currency = v
            default:
                continue
            }
        }
        flush()
        return events.isEmpty ? nil : events
    }
}
#endif
