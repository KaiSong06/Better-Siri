import Foundation
import MessageUI
import UIKit

/// Manages the two-stage voice-driven text message compose flow.
///
/// ## Stage 1 — prepare
/// `prepare(name:number:body:)` resolves the recipient via `ContactService` and
/// stores a `PendingMessage`. Returns a result string for Groq, which uses it
/// to ask the user for confirmation (ending with "?", which triggers the
/// existing follow-up listen in `VoicePipeline`).
///
/// ## Stage 2 — confirm or cancel
/// After the user says "yes" / "confirm" Groq calls `confirm_message`, which
/// presents `MFMessageComposeViewController` pre-filled with recipient + body.
/// After the user says "cancel" Groq calls `cancel_message`, which dismisses
/// any open sheet and clears the pending state.
///
/// ## iOS note
/// `MFMessageComposeViewController` does not expose a programmatic send API.
/// The compose sheet is pre-filled; the user taps Send to deliver the message.
/// Voice "cancel" dismisses the sheet without sending.
///
/// ## Threading
/// `@MainActor` throughout — UIKit presentation requires the main thread, and
/// all callers reach this class through `await` from the detached pipeline loop.
@MainActor
final class MessageHandler: NSObject, MFMessageComposeViewControllerDelegate {

    // MARK: – Pending state

    struct PendingMessage {
        let displayName: String
        let phoneNumber: String
        let body:        String
    }

    private let contacts: ContactService
    private var pending:  PendingMessage?
    private var composeVC: MFMessageComposeViewController?

    // MARK: – Init

    init(contacts: ContactService) {
        self.contacts = contacts
    }

    // MARK: – Tool actions

    /// Resolves the recipient and stores the pending message for confirmation.
    ///
    /// Returns a plain-text result string that Groq will speak back to the user,
    /// ideally phrased as a yes/no question to trigger the pipeline's follow-up
    /// listen (e.g. "Should I send it?").
    func prepare(name: String?, number: String?, body: String) async -> String {
        pending = nil

        let displayName: String
        let phoneNumber: String

        if let name {
            do {
                let resolved = try await contacts.resolve(name: name)
                displayName = resolved.displayName
                phoneNumber = resolved.phoneNumber
            } catch ContactService.ContactError.permissionDenied {
                return "Contacts access isn't granted. Please allow it in Settings."
            } catch ContactService.ContactError.notFound(let n) {
                if let raw = number {
                    displayName = raw
                    phoneNumber = raw
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
            displayName = raw
            phoneNumber = raw
        } else {
            return "No recipient name or number provided."
        }

        pending = PendingMessage(displayName: displayName, phoneNumber: phoneNumber, body: body)
        return "Pending message to \(displayName): '\(body)'. Awaiting user confirmation."
    }

    /// Presents the compose sheet with the pending message pre-filled.
    ///
    /// Called when the user confirms they want to send the message.
    /// The user taps Send inside the sheet to deliver it.
    func confirm() -> String {
        guard let msg = pending else {
            return "No message is pending. Please try again."
        }

        guard MFMessageComposeViewController.canSendText() else {
            return "This device cannot send SMS messages."
        }

        let vc = MFMessageComposeViewController()
        vc.recipients             = [ContactService.dialable(msg.phoneNumber)]
        vc.body                   = msg.body
        vc.messageComposeDelegate = self
        composeVC = vc

        guard let top = topViewController() else {
            return "Unable to present the message composer."
        }
        top.present(vc, animated: true)

        return "Message compose sheet opened for \(msg.displayName). Tap send to deliver it."
    }

    /// Dismisses any open compose sheet and clears the pending message.
    ///
    /// Called when the user cancels before or after the sheet appears.
    func cancel() -> String {
        let recipientName = pending?.displayName ?? "the message"
        pending = nil

        if let vc = composeVC {
            vc.dismiss(animated: true)
            composeVC = nil
        }

        return "Message to \(recipientName) cancelled."
    }

    // MARK: – MFMessageComposeViewControllerDelegate

    nonisolated func messageComposeViewController(
        _ controller: MFMessageComposeViewController,
        didFinishWith result: MessageComposeResult
    ) {
        Task { @MainActor in
            controller.dismiss(animated: true)
            self.composeVC = nil
            self.pending   = nil
        }
    }

    // MARK: – Helpers

    private func topViewController() -> UIViewController? {
        guard
            let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState == .foregroundActive }),
            let root = scene.windows.first(where: { $0.isKeyWindow })?.rootViewController
        else { return nil }

        var top: UIViewController = root
        while let presented = top.presentedViewController { top = presented }
        return top
    }
}
