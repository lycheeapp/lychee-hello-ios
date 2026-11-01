import SwiftUI

/// The payment a POS asked for: the amount, who it is for, the card that pays — the one in front,
/// or the nearest one that can when it cannot — and one button. Nothing is paid until it is pressed.
struct TapPaySheet: View {
    @Bindable var model: CardsModel
    let onDone: () -> Void

    var body: some View {
        ScrollView {
            Group {
                switch model.pay {
                case .idle, .reading:
                    reading
                case let .ready(_, preview, cardId, paying, error):
                    ready(preview: preview, cardId: cardId, paying: paying, error: error)
                case let .paid(receipt, card):
                    TapPaidView(receipt: receipt, card: card, onDone: onDone)
                case let .failed(message, payload):
                    failed(message: message, canRetry: payload != nil)
                }
            }
            .padding(.horizontal, Tokens.Spacing.gutter)
            .padding(.top, Tokens.Spacing.xl)
            .padding(.bottom, Tokens.Spacing.lg)
            .animation(.easeInOut(duration: 0.25), value: model.pay)
        }
        .background(Tokens.Colour.surface.ignoresSafeArea())
        .sensoryFeedback(trigger: model.pay) { _, new in
            switch new {
            case .paid: return .success
            case .failed: return .error
            default: return nil
            }
        }
    }

    private var reading: some View {
        VStack(spacing: Tokens.Spacing.md) {
            ProgressView().tint(Tokens.Colour.brand).controlSize(.large)
            Text(L("tap_reading"))
                .font(Tokens.Typography.body)
                .foregroundStyle(Tokens.Colour.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Tokens.Spacing.xxl)
    }

    private func ready(preview: TapPreview, cardId: String, paying: Bool, error: String?) -> some View {
        let option = preview.option(cardId)
        let chosen = model.wallet?.cards.first { $0.id == cardId }
        let payee = preview.storeName.map(\.bidiIsolated) ?? L("tap_bus")
        // The cards worth offering: front first, then the rest of the stack front to back.
        let choices = Array(model.cards.reversed())
        return TimelineView(.periodic(from: .now, by: 1)) { context in
            let left = secondsLeft(preview.expiresAt, now: context.date)
            let expired = left.map { $0 <= 0 } ?? false
            VStack(spacing: Tokens.Spacing.xs) {
                Text(L("tap_pay_to", payee))
                    .font(Tokens.Typography.body)
                    .foregroundStyle(Tokens.Colour.textSecondary)
                    .multilineTextAlignment(.center)
                Text(Money.format(preview.amount))
                    .font(.system(size: 44, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(Tokens.Colour.textPrimary)
                    .environment(\.layoutDirection, .leftToRight)
                if let left {
                    Text(expired ? L("tap_expired") : L("tap_expires_in", clock(left)))
                        .font(Tokens.Typography.caption)
                        .foregroundStyle(expired || left <= 10 ? Tokens.Colour.danger : Tokens.Colour.textSecondary)
                        .multilineTextAlignment(.center)
                        .monospacedDigit()
                }

                Text(L("tap_pay_with"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Tokens.Colour.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, Tokens.Spacing.lg)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Tokens.Spacing.sm) {
                        ForEach(choices) { card in
                            MiniCard(card: card, chosen: card.id == cardId, usable: preview.canPay(with: card.id)) {
                                withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                                    model.choosePayCard(card.id)
                                }
                            }
                        }
                    }
                    .padding(.vertical, Tokens.Spacing.sm)
                    .padding(.horizontal, 2)
                }
                .sensoryFeedback(.selection, trigger: cardId)

                if option?.usable != true {
                    let reason = option?.reason ?? (chosen?.storeName != nil ? "other_store" : nil)
                    Text(L("tap_card_cannot_pay", CardCopy.reason(reason, store: chosen?.storeName)))
                        .font(Tokens.Typography.caption)
                        .foregroundStyle(Tokens.Colour.danger)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if let error {
                    Text(error)
                        .font(Tokens.Typography.callout)
                        .foregroundStyle(Tokens.Colour.danger)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, Tokens.Spacing.xs)
                }

                LHPrimaryButton(title: L("tap_pay_button", Money.format(preview.amount)),
                                isLoading: paying,
                                isEnabled: option?.usable == true && !expired && !paying) {
                    Task { await model.confirmPay() }
                }
                .padding(.top, Tokens.Spacing.lg)
                // Not while paying: with "Confirm before paying" off, the payment is already on its way.
                if !paying {
                    Label(L("tap_nothing_until"), systemImage: "lock")
                        .font(.caption)
                        .foregroundStyle(Tokens.Colour.textSecondary)
                        .padding(.top, Tokens.Spacing.xs)
                }
            }
        }
    }

    private func failed(message: String, canRetry: Bool) -> some View {
        VStack(spacing: Tokens.Spacing.sm) {
            Image(systemName: "exclamationmark.circle")
                .font(.system(size: 52))
                .foregroundStyle(Tokens.Colour.danger)
            Text(L("tap_failed_title"))
                .font(Tokens.Typography.headline)
                .foregroundStyle(Tokens.Colour.textPrimary)
            Text(message)
                .font(Tokens.Typography.body)
                .foregroundStyle(Tokens.Colour.textSecondary)
                .multilineTextAlignment(.center)
            if canRetry {
                LHPrimaryButton(title: L("common_try_again")) { Task { await model.retry() } }
                    .padding(.top, Tokens.Spacing.lg)
            }
            Button(L("common_close")) { model.dismissPay() }
                .foregroundStyle(Tokens.Colour.textSecondary)
                .frame(minHeight: Tokens.Hit.minimum)
        }
        .frame(maxWidth: .infinity)
    }

    private func secondsLeft(_ expiresAt: Int64?, now: Date) -> Int? {
        guard let expiresAt else { return nil }
        return max(0, Int((Double(expiresAt) / 1000 - now.timeIntervalSince1970).rounded(.down)))
    }

    private func clock(_ seconds: Int) -> String {
        String(format: "%d:%02d", locale: Locale(identifier: "en_US_POSIX"), seconds / 60, seconds % 60)
    }
}

/// The receipt: a check that pops in, what was paid, to whom, and what is left on the card.
private struct TapPaidView: View {
    let receipt: TapReceipt
    let card: WalletCard?
    let onDone: () -> Void
    @State private var popped = false

    var body: some View {
        VStack(spacing: Tokens.Spacing.xs) {
            Image(systemName: "checkmark")
                .font(.system(size: 40, weight: .bold))
                .foregroundStyle(Tokens.Colour.textOnBrand)
                .frame(width: 76, height: 76)
                .background(Circle().fill(Tokens.Colour.brand))
                .scaleEffect(popped ? 1 : 0.4)
                .animation(.spring(response: 0.42, dampingFraction: 0.5), value: popped)
                .padding(.bottom, Tokens.Spacing.sm)
            Text(L("tap_paid_title"))
                .font(Tokens.Typography.headline)
                .foregroundStyle(Tokens.Chat.success)
            Text(Money.format(receipt.amount))
                .font(.system(size: 40, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(Tokens.Colour.textPrimary)
                .environment(\.layoutDirection, .leftToRight)
            Text(L("tap_paid_to", receipt.storeName.map(\.bidiIsolated) ?? L("tap_bus")))
                .font(Tokens.Typography.body)
                .foregroundStyle(Tokens.Colour.textPrimary)
            if let left = receipt.newBalance {
                Text(L("tap_left_on", Money.format(left), (card?.from ?? card?.title ?? "").bidiIsolated))
                    .font(Tokens.Typography.callout)
                    .foregroundStyle(Tokens.Colour.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.top, Tokens.Spacing.xs)
            }
            LHPrimaryButton(title: L("tap_done"), action: onDone)
                .padding(.top, Tokens.Spacing.xl)
        }
        .frame(maxWidth: .infinity)
        .onAppear { popped = true }
    }
}

/// A small card in the pay sheet's chooser; a check marks the one that pays.
struct MiniCard: View {
    let card: WalletCard
    let chosen: Bool
    let usable: Bool
    let onTap: () -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        Button(action: onTap) {
            ZStack(alignment: .topTrailing) {
                VStack(alignment: .leading) {
                    Text((card.from ?? card.title ?? "").bidiIsolated)
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.9))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Text(Money.format(card.balance))
                        .font(.system(size: 20, weight: .bold))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .environment(\.layoutDirection, .leftToRight)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                if chosen {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .heavy))
                        .foregroundStyle(CardPalette.glow(card))
                        .frame(width: 20, height: 20)
                        .background(Circle().fill(.white))
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .padding(12)
            .frame(width: 150, height: 94)
            .background(shape.fill(CardPalette.gradient(card)))
            .overlay(shape.strokeBorder(.white.opacity(chosen ? 0.9 : 0), lineWidth: 2))
            .shadow(color: CardPalette.glow(card).opacity(chosen ? 0.45 : 0), radius: 8, y: 4)
            .scaleEffect(chosen ? 1 : 0.94)
            .opacity(usable ? 1 : 0.45)
        }
        .buttonStyle(.plain)
        .disabled(!usable)
        .accessibilityLabel(CardCopy.accessibility(card, selected: chosen))
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }
}

/// A new OnePay voucher, paid from the balance: the amount on the keypad, the rules (limits, how
/// long it lasts, the terms) and an explicit "I accept" — the Lychee app's creation.
struct CreateVoucherSheet: View {
    @Bindable var model: CardsModel

    var body: some View {
        let create = model.create ?? CreateState()
        let problem = model.amountProblem()
        ScrollView {
            VStack(spacing: Tokens.Spacing.sm) {
                Text(title(create.settings))
                    .font(Tokens.Typography.title)
                    .foregroundStyle(Tokens.Colour.textPrimary)
                    .multilineTextAlignment(.center)
                Text(L("onepay_create_body"))
                    .font(Tokens.Typography.callout)
                    .foregroundStyle(Tokens.Colour.textSecondary)
                    .multilineTextAlignment(.center)

                if create.loading {
                    ProgressView().tint(Tokens.Colour.brand).padding(.vertical, Tokens.Spacing.xxl)
                } else {
                    amountDisplay(create.amount)
                        .padding(.top, Tokens.Spacing.md)
                    Text(problem ?? rangeHint(create) ?? L("onepay_balance", Money.format(model.balance?.balance)))
                        .font(Tokens.Typography.caption)
                        .foregroundStyle(problem != nil ? Tokens.Colour.danger : Tokens.Colour.textSecondary)
                    keypad
                    VStack(alignment: .leading, spacing: 2) {
                        Text(validityLabel(create.settings?.validity))
                        ForEach(Array((create.settings?.terms ?? []).filter { !$0.isEmpty }.enumerated()), id: \.offset) { _, term in
                            Text("• \(term)")
                        }
                    }
                    .font(Tokens.Typography.caption)
                    .foregroundStyle(Tokens.Colour.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Button {
                        model.create?.accepted.toggle()
                    } label: {
                        HStack(spacing: Tokens.Spacing.sm) {
                            Image(systemName: create.accepted ? "checkmark.square.fill" : "square")
                                .font(.system(size: 22))
                                .foregroundStyle(create.accepted ? Tokens.Colour.brand : Tokens.Colour.textSecondary)
                            Text(L("onepay_accept"))
                                .font(Tokens.Typography.callout)
                                .foregroundStyle(Tokens.Colour.textPrimary)
                                .multilineTextAlignment(.leading)
                            Spacer(minLength: 0)
                        }
                        .frame(minHeight: Tokens.Hit.minimum)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(create.accepted ? .isSelected : [])

                    if let error = create.error {
                        Text(error)
                            .font(Tokens.Typography.callout)
                            .foregroundStyle(Tokens.Colour.danger)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    LHPrimaryButton(title: L("onepay_create_button"),
                                    isLoading: create.submitting,
                                    isEnabled: AmountInput.value(create.amount) != nil && create.accepted && problem == nil && !create.submitting) {
                        Task { await model.submitCreate() }
                    }
                    .padding(.top, Tokens.Spacing.sm)
                }
            }
            .padding(.horizontal, Tokens.Spacing.gutter)
            .padding(.top, Tokens.Spacing.xl)
            .padding(.bottom, Tokens.Spacing.lg)
        }
        .background(Tokens.Colour.surface.ignoresSafeArea())
        .interactiveDismissDisabled(create.submitting)
    }

    private func amountDisplay(_ amount: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 2) {
            Text(Money.symbol)
                .font(.system(size: 30, weight: .semibold))
            Text(amount.isEmpty ? "0" : amount)
                .font(.system(size: 48, weight: .bold))
                .monospacedDigit()
            Rectangle()
                .fill(Tokens.Colour.brand)
                .frame(width: 2, height: 40)
        }
        .foregroundStyle(amount.isEmpty ? Tokens.Colour.textSecondary : Tokens.Colour.navy)
        .environment(\.layoutDirection, .leftToRight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L("pay_amount"))
        .accessibilityValue(Money.symbol + (amount.isEmpty ? "0" : amount))
    }

    /// A phone keypad. Never mirrored: digits sit where a hand expects them in either language.
    private var keypad: some View {
        let rows: [[String]] = [["1", "2", "3"], ["4", "5", "6"], ["7", "8", "9"], [".", "0", "⌫"]]
        return VStack(spacing: 2) {
            ForEach(rows, id: \.self) { row in
                HStack(spacing: 0) {
                    ForEach(row, id: \.self) { key in
                        Button {
                            if key == "⌫" { model.deleteDigit() } else if let c = key.first { model.press(c) }
                        } label: {
                            Group {
                                if key == "⌫" {
                                    Image(systemName: "delete.left").font(.system(size: 22, weight: .medium))
                                } else {
                                    Text(key).font(.system(size: 28, weight: .medium))
                                }
                            }
                            .foregroundStyle(Tokens.Colour.navy)
                            .frame(maxWidth: .infinity, minHeight: 52)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(key == "⌫" ? L("pay_delete") : key)
                    }
                }
            }
        }
        .environment(\.layoutDirection, .leftToRight)
    }

    private func title(_ settings: OnePaySettings?) -> String {
        guard let name = settings?.voucherName, !name.isEmpty else { return L("onepay_create_title") }
        return name
    }

    private func rangeHint(_ create: CreateState) -> String? {
        guard let min = create.settings?.min, let max = create.settings?.max, create.amount.isEmpty else { return nil }
        return L("onepay_range", Money.format(min), Money.format(max))
    }

    private func validityLabel(_ validity: String?) -> String {
        switch validity {
        case "ONE_MONTH": return L("onepay_valid_one_month")
        case "THREE_MONTHS": return L("onepay_valid_three_months")
        case "SIX_MONTHS": return L("onepay_valid_six_months")
        case "ONE_YEAR": return L("onepay_valid_one_year")
        default: return L("onepay_valid_permanent")
        }
    }
}
