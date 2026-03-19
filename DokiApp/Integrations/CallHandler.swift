import Foundation
import UIKit

/// Places a phone call by resolving a contact name or dialling a literal number.
///
/// ## Design
/// Value type — no mutable state. Contact resolution is delegated to
/// `ContactService`. Opening the tel:// URL always hops to `@MainActor`
/// (UIApplication requirement). Never throws — errors are plain strings
/// for Groq to speak back to the user.
struct CallHandler {

    private let contacts: ContactService

    init(contacts: ContactService) {
        self.contacts = contacts
    }

    // MARK: – Public

    /// Resolves the target and opens the Phone dialler.
    ///
    /// - Parameters:
    ///   - name:   Display name to look up in Contacts (preferred).
    ///   - number: Literal phone number used when `name` is nil or resolution fails.
    func call(name: String?, number: String?) async -> String {
        let phoneNumber: String
        let displayName: String

        if let name {
            do {
                let resolved = try await contacts.resolve(name: name)
                phoneNumber = resolved.phoneNumber
                displayName = resolved.displayName
            } catch ContactService.ContactError.permissionDenied {
                return "Contacts access isn't granted. Please allow it in Settings."
            } catch ContactService.ContactError.notFound(let n) {
                // Fall back to a literal number if one was also supplied.
                if let raw = number {
                    phoneNumber = raw
                    displayName = raw
                } else {
                    return "I couldn't find \(n) in your contacts."
                }
            } catch ContactService.ContactError.ambiguous(let n, let matches) {
                let names = matches.prefix(3).map(\.displayName).joined(separator: ", ")
                return "I found several people named \(n): \(names). Which one did you mean?"
            } catch ContactService.ContactError.noPhoneNumber(let n) {
                return "\(n) doesn't have a phone number saved in your contacts."
            } catch {
                return "I couldn't look up that contact."
            }
        } else if let raw = number {
            phoneNumber = raw
            displayName = raw
        } else {
            return "No contact name or phone number provided."
        }

        let dialable = ContactService.dialable(phoneNumber)
        guard !dialable.isEmpty,
              let url = URL(string: "tel://\(dialable)") else {
            return "That doesn't look like a valid phone number."
        }

        await openURL(url)
        return "Calling \(displayName)."
    }

    // MARK: – Helpers

    @MainActor
    private func openURL(_ url: URL) {
        UIApplication.shared.open(url, options: [:], completionHandler: nil)
    }
}
