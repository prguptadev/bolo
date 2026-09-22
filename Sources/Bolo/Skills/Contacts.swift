import BoloCore
import Contacts
import Foundation

struct Person {
    var displayName: String
    var phone: String?
    var email: String?
    var channel: Channel?
}

enum ResolveError: LocalizedError {
    case unknown(String)
    case ambiguous(String, [String])

    var errorDescription: String? {
        switch self {
        case .unknown(let who):
            "I don't know who \"\(who)\" is. Add them to Contacts (Nickname field) or to Nicknames in the menu bar."
        case .ambiguous(let who, let names):
            "\"\(who)\" matches \(names.prefix(3).joined(separator: ", ")). Say the full name, or add a nickname."
        }
    }
}

/// Resolves a spoken name to a person: nicknames file first, then Contacts (nickname, first, full name).
/// Autonomous mode never guesses between two people.
final class ContactBook: @unchecked Sendable {
    private struct Entry {
        let given: String, family: String, nickname: String
        let phones: [String], emails: [String]
        var full: String { [given, family].filter { !$0.isEmpty }.joined(separator: " ") }
    }

    private var entries: [Entry] = []
    private var nicknames: [String: Nickname] = [:]
    private let lock = NSLock()

    /// Names the phrase parser can recognise at the start of a message.
    var spokenNames: [String] {
        lock.lock(); defer { lock.unlock() }
        var names = Array(nicknames.keys)
        for e in entries {
            names.append(contentsOf: [e.given, e.full, e.nickname].filter { !$0.isEmpty })
        }
        return names
    }

    func reload() async {
        let nicks = Nicknames.load()
        var loaded: [Entry] = []
        let store = CNContactStore()
        if (try? await store.requestAccess(for: .contacts)) == true {
            let keys = [
                CNContactGivenNameKey, CNContactFamilyNameKey, CNContactNicknameKey,
                CNContactPhoneNumbersKey, CNContactEmailAddressesKey,
            ] as [CNKeyDescriptor]
            let request = CNContactFetchRequest(keysToFetch: keys)
            try? store.enumerateContacts(with: request) { c, _ in
                loaded.append(
                    Entry(
                        given: c.givenName, family: c.familyName, nickname: c.nickname,
                        phones: c.phoneNumbers.map { $0.value.stringValue },
                        emails: c.emailAddresses.map { $0.value as String }))
            }
        }
        lock.withLock {
            entries = loaded
            nicknames = nicks
        }
    }

    func resolve(_ spoken: String) throws -> Person {
        let who = spoken.lowercased().trimmingCharacters(in: .whitespaces)
        lock.lock(); defer { lock.unlock() }

        if let n = nicknames[who] {
            var person = Person(displayName: n.name ?? spoken, phone: n.phone, email: n.email, channel: n.channel.flatMap(Channel.from(spoken:)))
            // Fill missing details from Contacts when the nickname names someone there.
            if let name = n.name?.lowercased(), let e = entries.first(where: { $0.full.lowercased() == name || $0.given.lowercased() == name }) {
                person.phone = person.phone ?? e.phones.first
                person.email = person.email ?? e.emails.first
            }
            return person
        }

        let exact = entries.filter {
            $0.nickname.lowercased() == who || $0.full.lowercased() == who || $0.given.lowercased() == who
        }
        let pool = exact.isEmpty ? entries.filter { $0.full.lowercased().hasPrefix(who + " ") } : exact
        let byName = Dictionary(grouping: pool, by: { $0.full.lowercased() })
        guard let first = pool.first else {
            // Misheard by one letter ("pria")? Only if exactly one known name is that close.
            let known = Array(nicknames.keys) + entries.flatMap { [$0.nickname, $0.given, $0.full] }.filter { !$0.isEmpty }
            if let close = Fuzzy.uniqueClose(who, in: known), close != who {
                lock.unlock()
                defer { lock.lock() }
                Log.agent.info("contact \(spoken, privacy: .public) matched \(close, privacy: .public) by spelling")
                return try resolve(close)
            }
            throw ResolveError.unknown(spoken)
        }
        if byName.count > 1 {
            // A nickname match beats first-name matches.
            let nick = pool.filter { $0.nickname.lowercased() == who }
            guard nick.count == 1 else { throw ResolveError.ambiguous(spoken, byName.values.compactMap { $0.first?.full }) }
            return Person(displayName: nick[0].full, phone: nick[0].phones.first, email: nick[0].emails.first)
        }
        return Person(displayName: first.full, phone: first.phones.first, email: first.emails.first)
    }
}
