import Contacts
import Foundation

/// Resolves contact names and phone numbers from the system Contacts database.
///
/// ## Design
/// `actor` isolation keeps CNContactStore access off the main thread and
/// prevents concurrent queries from racing. All public methods are async
/// so callers never block.
actor ContactService {

    // MARK: – Errors

    enum ContactError: Error {
        case permissionDenied
        case notFound(name: String)
        case ambiguous(name: String, matches: [(displayName: String, phoneNumber: String)])
        case noPhoneNumber(name: String)
    }

    // MARK: – State

    private let store = CNContactStore()
    private(set) var authorized = false

    // MARK: – Permission

    func requestPermission() async {
        let status = CNContactStore.authorizationStatus(for: .contacts)
        switch status {
        case .authorized:
            authorized = true
        case .notDetermined:
            authorized = (try? await store.requestAccess(for: .contacts)) ?? false
        default:
            authorized = false
        }
    }

    // MARK: – Resolution

    /// Resolves a display name to a single (displayName, phoneNumber) pair.
    ///
    /// - Throws `ContactError.ambiguous` when multiple distinct contacts match.
    /// - Throws `ContactError.notFound` when no contacts match.
    /// - Throws `ContactError.noPhoneNumber` when a contact exists but has no phone number.
    func resolve(name: String) async throws -> (displayName: String, phoneNumber: String) {
        guard authorized else { throw ContactError.permissionDenied }

        let keys: [CNKeyDescriptor] = [
            CNContactGivenNameKey  as CNKeyDescriptor,
            CNContactFamilyNameKey as CNKeyDescriptor,
            CNContactPhoneNumbersKey as CNKeyDescriptor
        ]

        let predicate = CNContact.predicateForContacts(matchingName: name)
        let contacts: [CNContact]
        do {
            contacts = try store.unifiedContacts(matching: predicate, keysToFetch: keys)
        } catch {
            throw ContactError.notFound(name: name)
        }

        guard !contacts.isEmpty else {
            throw ContactError.notFound(name: name)
        }

        // Prefer mobile numbers; fall back to first available.
        func bestNumber(for contact: CNContact) -> String? {
            let mobile = contact.phoneNumbers.first(where: { label in
                label.label == CNLabelPhoneNumberMobile || label.label == CNLabelPhoneNumberiPhone
            })?.value.stringValue
            return mobile ?? contact.phoneNumbers.first?.value.stringValue
        }

        if contacts.count == 1 {
            let contact = contacts[0]
            let fullName = fullName(for: contact).isEmpty ? name : fullName(for: contact)
            guard let number = bestNumber(for: contact) else {
                throw ContactError.noPhoneNumber(name: fullName)
            }
            return (displayName: fullName, phoneNumber: number)
        }

        // Multiple matches — collect those that actually have numbers.
        let candidates: [(displayName: String, phoneNumber: String)] = contacts.compactMap { c in
            guard let number = bestNumber(for: c) else { return nil }
            return (fullName(for: c).isEmpty ? name : fullName(for: c), number)
        }

        guard !candidates.isEmpty else {
            throw ContactError.noPhoneNumber(name: name)
        }

        if candidates.count == 1 {
            return candidates[0]
        }

        throw ContactError.ambiguous(name: name, matches: candidates)
    }

    // MARK: – Helpers

    private func fullName(for contact: CNContact) -> String {
        "\(contact.givenName) \(contact.familyName)"
            .trimmingCharacters(in: .whitespaces)
    }

    /// Strips everything from a phone number string except digits and a leading `+`,
    /// producing a value safe to embed in a `tel://` URL.
    static func dialable(_ raw: String) -> String {
        var result = ""
        for (i, ch) in raw.enumerated() {
            if ch == "+" && i == 0 { result.append(ch) }
            else if ch.isNumber    { result.append(ch) }
        }
        return result
    }
}
