import CoreNFC
import Foundation

/// Reads the payment request a Lychee POS shows on its Tap to pay screen.
///
/// The POS (the `pos-branch` of lychee-android) emulates an NFC Forum Type 4 tag whose NDEF file
/// holds one URI record: `https://<host>/pay?p=<signed payload>`. Core NFC reads it in an NDEF
/// reader session — the system sheet that says "Hold your iPhone near the POS" — and the app pays it
/// with the chosen card.
///
/// Needs the Near Field Communication Tag Reading capability (`LycheeHello.entitlements`) and
/// `NFCReaderUsageDescription` in Info.plist; an iPhone 7 or later.
@MainActor
final class PosTagReader: NSObject {

    enum ReaderError: Error {
        /// No NFC on this device (iPad, Simulator) or the capability is missing.
        case unavailable
        /// The session ended without reading a tag: timed out, or the system stopped it.
        case failed(String)
    }

    static var isAvailable: Bool { NFCNDEFReaderSession.readingAvailable }

    private var session: NFCNDEFReaderSession?
    private var continuation: CheckedContinuation<String?, Error>?

    /// The first URI on the tag the user holds the phone to; nil when they cancel.
    func read(prompt: String) async throws -> String? {
        guard Self.isAvailable else { throw ReaderError.unavailable }
        finish(.success(nil))
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let session = NFCNDEFReaderSession(delegate: self, queue: nil, invalidateAfterFirstRead: true)
            session.alertMessage = prompt
            self.session = session
            session.begin()
        }
    }

    /// Closes the system sheet with a word for the user ("Paid", "Reading…"), if one is open.
    func close(message: String? = nil) {
        if let message { session?.alertMessage = message }
        session?.invalidate()
        session = nil
    }

    private func finish(_ result: Result<String?, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(with: result)
    }
}

extension PosTagReader: NFCNDEFReaderSessionDelegate {

    nonisolated func readerSession(_ session: NFCNDEFReaderSession, didDetectNDEFs messages: [NFCNDEFMessage]) {
        let url = messages
            .flatMap(\.records)
            .compactMap { $0.wellKnownTypeURIPayload()?.absoluteString }
            .first
        Task { @MainActor in self.finish(.success(url)) }
    }

    nonisolated func readerSession(_ session: NFCNDEFReaderSession, didInvalidateWithError error: Error) {
        let code = (error as? NFCReaderError)?.code
        let message = error.localizedDescription
        Task { @MainActor in
            self.session = nil
            switch code {
            case .readerSessionInvalidationErrorUserCanceled, .readerSessionInvalidationErrorFirstNDEFTagRead:
                // Cancelled, or the normal end after a read (which already finished).
                self.finish(.success(nil))
            default:
                self.finish(.failure(ReaderError.failed(message)))
            }
        }
    }

    nonisolated func readerSessionDidBecomeActive(_ session: NFCNDEFReaderSession) {}
}
