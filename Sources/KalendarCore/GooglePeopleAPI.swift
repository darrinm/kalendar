// People API v1 (§18.4): saved contacts, "other contacts", and the Workspace directory.
import Foundation

public enum GooglePeopleAPI {
    static let base = "https://people.googleapis.com/v1"
    /// What Kalendar reads from each person: the same for all three lists.
    static let fields = "names,emailAddresses,photos"

    public enum Source: CaseIterable {
        case connections, otherContacts, directory

        func request(pageToken: String?) -> GoogleCalendarAPI.Builder {
            { token in
                var c: URLComponents
                switch self {
                case .connections:
                    c = URLComponents(string: base + "/people/me/connections")!
                    c.queryItems = [.init(name: "personFields", value: fields)]
                case .otherContacts:
                    c = URLComponents(string: base + "/otherContacts")!
                    c.queryItems = [.init(name: "readMask", value: fields)]
                case .directory:
                    c = URLComponents(string: base + "/people:listDirectoryPeople")!
                    c.queryItems = [.init(name: "readMask", value: fields),
                                    .init(name: "sources", value: "DIRECTORY_SOURCE_TYPE_DOMAIN_PROFILE")]
                }
                c.queryItems! += [.init(name: "pageSize", value: "1000")]
                if let pageToken { c.queryItems!.append(.init(name: "pageToken", value: pageToken)) }
                var r = URLRequest(url: c.url!)
                r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                return r
            }
        }
    }

    /// One page of any of the three lists; they differ only in the array's name.
    public struct Page: GoogleCalendarAPI.Paged {
        struct Person: Decodable {
            struct Name: Decodable { var displayName: String? }
            struct Email: Decodable {
                struct Metadata: Decodable {
                    struct Source: Decodable { var type: String? }
                    var primary: Bool?
                    var source: Source?
                }
                var value: String?
                /// "home", "work", …; none on a directory person's aliases.
                var type: String?
                var metadata: Metadata?

                /// A Workspace directory profile lists the person's primary address, the addresses
                /// they gave (typed, such as a personal "home" one), and the domain's aliases for
                /// them (untyped, such as old domains').
                var isDirectoryAlias: Bool {
                    metadata?.source?.type == "DOMAIN_PROFILE" && metadata?.primary != true && type == nil
                }
            }
            struct Photo: Decodable { var url: String?; var `default`: Bool? }
            var names: [Name]?
            var emailAddresses: [Email]?
            var photos: [Photo]?
        }
        public var nextPageToken: String?
        var connections: [Person]?
        var otherContacts: [Person]?
        var people: [Person]?

        /// One contact per email address; a person with two addresses is two rows (§5.1). A
        /// directory alias is kept, marked, so `CalendarCache.allContacts` can leave it out wherever
        /// else it turns up.
        public func contacts(account: String) -> [Contact] {
            (connections ?? otherContacts ?? people ?? []).flatMap { p -> [Contact] in
                let name = p.names?.first?.displayName
                let photo = p.photos?.first { $0.default != true }?.url
                return (p.emailAddresses ?? []).compactMap { e in
                    e.value.map { Contact(account: account, email: $0, name: name, photoURL: photo, isAlias: e.isDirectoryAlias) }
                }
            }
        }
    }
}
