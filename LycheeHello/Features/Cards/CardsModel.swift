import Foundation
import Observation

/// A payment at a POS, from reading its tag to the receipt.
enum PayState: Equatable {
    case idle
    /// The tag was read; the request is being fetched.
    case reading
    /// Ready to pay: what, to whom, and with which card.
    case ready(payload: String, preview: TapPreview, cardId: String, paying: Bool, error: String?)
    case paid(receipt: TapReceipt, card: WalletCard?)
    /// Nothing to pay: the tag was not Lychee's, the request had expired, the network failed.
    case failed(message: String, payload: String?)

    var isPresented: Bool { self != .idle }
}

/// Creating a OnePay voucher from the balance.
struct CreateState: Equatable {
    var settings: OnePaySettings?
    var loading = true
    var amount = ""
    var accepted = false
    var submitting = false
    var error: String?
}

/// The Cards tab.
///
/// The stack is ordered so the chosen card is in front (last). Choosing another swaps the two — the
/// new card comes to the front and the old one takes its place — which is what the screen animates.
/// The choice is remembered on this phone; the first time it is the Tap&Pay default the user set in
/// the Lychee app, if any, or the balance.
@Observable
@MainActor
final class CardsModel {

    static let walletId = "WALLET"

    private(set) var wallet: Wallet?
    private(set) var isLoading = true
    private(set) var error: String?
    /// Card ids top to bottom; the last one is in front — the chosen card.
    private(set) var order: [String] = []
    var pay: PayState = .idle
    var create: CreateState?

    private let repository: HelloRepositoryProtocol
    private let defaults: UserDefaults
    private var accountKey = "0"

    init(repository: HelloRepositoryProtocol, defaults: UserDefaults = .standard) {
        self.repository = repository
        self.defaults = defaults
    }

    var cards: [WalletCard] { order.compactMap { id in wallet?.cards.first { $0.id == id } } }
    var selected: WalletCard? { cards.last }
    var balance: WalletCard? { wallet?.cards.first { $0.id == Self.walletId } }

    // MARK: - The stack

    func start(accountKey: String) async {
        self.accountKey = accountKey
        if wallet == nil { await load() }
    }

    func load() async {
        isLoading = wallet == nil
        error = nil
        do {
            apply(try await repository.wallet(), bringToFront: nil)
        } catch let failure as APIError {
            error = failure.userMessage
        } catch {
            self.error = L("cards_error_load")
        }
        isLoading = false
    }

    private func apply(_ wallet: Wallet, bringToFront: String?) {
        let ids = wallet.cards.map(\.id)
        let front = [bringToFront, order.last, remembered, wallet.defaultCardId, ids.first]
            .compactMap { $0 }
            .first { ids.contains($0) }
        self.wallet = wallet
        order = Self.arrange(previous: order, ids: ids, front: front)
        remembered = order.last
    }

    /// Chooses `cardId`: it trades places with the card in front.
    func select(_ cardId: String) {
        guard let index = order.firstIndex(of: cardId), index != order.count - 1 else { return }
        order.swapAt(index, order.count - 1)
        remembered = cardId
        if case let .ready(payload, preview, _, paying, _) = pay, !paying {
            pay = .ready(payload: payload, preview: preview, cardId: cardId, paying: false, error: nil)
        }
    }

    private var remembered: String? {
        get { defaults.string(forKey: "selectedCard:\(accountKey)") }
        set { defaults.set(newValue, forKey: "selectedCard:\(accountKey)") }
    }

    /// Keeps the user's arrangement across a refresh: known cards stay where they were, new ones
    /// join just behind the front, gone ones leave, and `front` ends up in front.
    static func arrange(previous: [String], ids: [String], front: String?) -> [String] {
        let kept = previous.filter { ids.contains($0) }
        let added = ids.filter { !kept.contains($0) }
        var order = Array(kept.dropLast()) + added + Array(kept.suffix(1))
        if let front, let index = order.firstIndex(of: front) {
            order.remove(at: index)
            order.append(front)
        }
        return order
    }

    // MARK: - Paying at a POS

    /// A tag was read.
    func tagRead(_ url: String?) async {
        if case .reading = pay { return }
        if case let .ready(_, _, _, paying, _) = pay, paying { return }
        guard let payload = TapLink.payload(url) else {
            pay = .failed(message: L("tap_not_lychee"), payload: nil)
            return
        }
        await preview(payload)
    }

    func retry() async {
        guard case let .failed(_, payload?) = pay else { return }
        await preview(payload)
    }

    private func preview(_ payload: String) async {
        pay = .reading
        do {
            let preview = try await repository.tapPreview(payload: payload)
            pay = .ready(payload: payload, preview: preview, cardId: payCard(for: preview), paying: false, error: nil)
        } catch let failure as APIError {
            pay = .failed(message: failure.userMessage, payload: failure.isRetryable ? payload : nil)
        } catch {
            pay = .failed(message: L("tap_failed_title"), payload: payload)
        }
    }

    /// The chosen card when it can pay this; otherwise the nearest card that can, front first.
    func payCard(for preview: TapPreview) -> String {
        if let front = order.last, preview.canPay(with: front) { return front }
        return order.reversed().first { preview.canPay(with: $0) } ?? order.last ?? Self.walletId
    }

    func choosePayCard(_ cardId: String) {
        guard case let .ready(payload, preview, _, paying, _) = pay, !paying else { return }
        pay = .ready(payload: payload, preview: preview, cardId: cardId, paying: false, error: nil)
    }

    func confirmPay() async {
        guard case let .ready(payload, preview, cardId, paying, _) = pay, !paying,
              preview.canPay(with: cardId) else { return }
        pay = .ready(payload: payload, preview: preview, cardId: cardId, paying: true, error: nil)
        do {
            let receipt = try await repository.tapPay(payload: payload, cardId: cardId)
            pay = .paid(receipt: receipt, card: wallet?.cards.first { $0.id == cardId })
            // The card's balance changed.
            if let fresh = try? await repository.wallet() { apply(fresh, bringToFront: nil) }
        } catch {
            let message = (error as? APIError)?.userMessage ?? L("tap_failed_title")
            pay = .ready(payload: payload, preview: preview, cardId: cardId, paying: false, error: message)
        }
    }

    func dismissPay() {
        if case let .ready(_, _, _, paying, _) = pay, paying { return }
        pay = .idle
    }

    // MARK: - A new OnePay voucher

    func openCreate() async {
        create = CreateState()
        do {
            let settings = try await repository.onePaySettings()
            create?.settings = settings
            create?.loading = false
        } catch {
            create?.loading = false
            create?.error = (error as? APIError)?.userMessage ?? L("cards_error_load")
        }
    }

    func press(_ key: Character) {
        guard var state = create else { return }
        state.amount = AmountInput.press(state.amount, key)
        state.error = nil
        create = state
    }

    func deleteDigit() {
        guard var state = create else { return }
        state.amount = String(state.amount.dropLast())
        state.error = nil
        create = state
    }

    /// Why the amount cannot be a voucher yet, or nil.
    func amountProblem() -> String? {
        guard let state = create, let value = AmountInput.value(state.amount) else { return nil }
        if let min = state.settings?.min, value < min { return L("onepay_too_low", Money.format(min)) }
        if let max = state.settings?.max, value > max { return L("onepay_too_high", Money.format(max)) }
        if let available = balance?.balance, value > available { return L("onepay_over_balance") }
        return nil
    }

    func submitCreate() async {
        guard var state = create, let amount = AmountInput.value(state.amount),
              state.accepted, !state.submitting, amountProblem() == nil else { return }
        state.submitting = true
        state.error = nil
        create = state
        do {
            let wallet = try await repository.createOnePay(amount: amount, acceptedTerms: true)
            apply(wallet, bringToFront: wallet.newCardId)
            create = nil
        } catch {
            create?.submitting = false
            create?.error = (error as? APIError)?.userMessage ?? L("tap_failed_title")
        }
    }

    func closeCreate() {
        if create?.submitting == true { return }
        create = nil
    }
}
