import SwiftUI

/// "Pay <store>": the amount on a keypad, from the balance or with a voucher — for a payee the app
/// already knows (a store in the directory, a "pay again" shortcut, a receipt), so nothing has to be
/// typed in the chat.
///
/// It does not pay. It hands the payee and amount to the chat, where the server composes the same
/// command a typed message would and the usual review card follows: one grammar, one confirmation.
///
/// The keypad types into whichever field is selected — the amount, or the voucher code — so the
/// system keyboard never covers the sheet.
struct PaySheet: View {

    let payee: PayeeRef
    let canPayFromBalance: Bool
    let onSubmit: (_ voucherCode: String?, _ amount: Double) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var amount: String
    @State private var useVoucher: Bool
    @State private var voucher = ""
    @State private var editingVoucher = false

    init(payee: PayeeRef, canPayFromBalance: Bool, onSubmit: @escaping (_ voucherCode: String?, _ amount: Double) -> Void) {
        self.payee = payee
        self.canPayFromBalance = canPayFromBalance
        self.onSubmit = onSubmit
        _amount = State(initialValue: AmountInput.initial(payee.lastAmount))
        // A wallet that cannot pay yet starts on the voucher: that is the payment that works.
        _useVoucher = State(initialValue: !canPayFromBalance)
    }

    private var value: Double? { AmountInput.value(amount) }

    private var isReady: Bool {
        guard value != nil else { return false }
        return useVoucher ? voucher.count >= VoucherInput.minLength : canPayFromBalance
    }

    private var typingVoucher: Bool { useVoucher && editingVoucher }

    var body: some View {
        ScrollView {
            VStack(spacing: Tokens.Spacing.lg) {
                header

                Picker(L("pay_source"), selection: $useVoucher) {
                    Text(L("pay_source_balance")).tag(false)
                    Text(L("pay_source_voucher")).tag(true)
                }
                .pickerStyle(.segmented)
                .disabled(!canPayFromBalance)
                .onChange(of: useVoucher) { _, voucherNow in
                    editingVoucher = voucherNow && voucher.isEmpty
                }

                if !canPayFromBalance {
                    Text(L("pay_wallet_not_active"))
                        .font(.footnote)
                        .foregroundStyle(Tokens.Colour.textSecondary)
                        .multilineTextAlignment(.center)
                }

                amountDisplay

                if useVoucher {
                    voucherField
                }

                keypad

                LHPrimaryButton(title: L("pay_review"), isEnabled: isReady) {
                    guard let value else { return }
                    onSubmit(useVoucher && !voucher.isEmpty ? voucher : nil, value)
                }

                Label(L("pay_nothing_until_confirm"), systemImage: "lock")
                    .font(.caption)
                    .foregroundStyle(Tokens.Colour.textSecondary)
            }
            .padding(.horizontal, Tokens.Spacing.gutter)
            .padding(.top, Tokens.Spacing.xl)
            .padding(.bottom, Tokens.Spacing.lg)
        }
        .background(Tokens.Colour.surface.ignoresSafeArea())
    }

    private var header: some View {
        VStack(spacing: 4) {
            PayeeAvatar(name: payee.name, size: 56)
            Text(L("pay_paying"))
                .font(.footnote)
                .foregroundStyle(Tokens.Colour.textSecondary)
                .padding(.top, 4)
            PayeeNameLine(name: payee.name, verified: payee.isMerchant, font: .title3.weight(.semibold))
            Text(payee.subtitle
                 ?? PaymentRecipient.summary(type: payee.type, category: payee.category, code: payee.code)
                 ?? payee.code)
                .font(.footnote)
                .foregroundStyle(Tokens.Colour.textSecondary)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }

    private var amountDisplay: some View {
        Button {
            editingVoucher = false
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(Money.symbol)
                    .font(.system(size: 30, weight: .semibold))
                Text(amount.isEmpty ? "0" : amount)
                    .font(.system(size: 48, weight: .bold))
                    .monospacedDigit()
                if !typingVoucher {
                    Rectangle()
                        .fill(Tokens.Colour.brand)
                        .frame(width: 2, height: 40)
                }
            }
            .foregroundStyle(amount.isEmpty ? Tokens.Colour.textSecondary : Tokens.Colour.navy)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Amounts read left to right in both languages, as on a receipt.
        .environment(\.layoutDirection, .leftToRight)
        .accessibilityLabel(L("pay_amount"))
        .accessibilityValue(Money.symbol + (amount.isEmpty ? "0" : amount))
    }

    private var voucherField: some View {
        Button {
            editingVoucher = true
        } label: {
            HStack(spacing: Tokens.Spacing.md) {
                Image(systemName: "ticket")
                    .foregroundStyle(Color(red: 0.5, green: 0.4, blue: 1))
                Text(voucher.isEmpty ? L("pay_voucher_code") : voucher)
                    .font(voucher.isEmpty ? .body : .body.monospaced())
                    .foregroundStyle(voucher.isEmpty ? Tokens.Colour.textSecondary : Tokens.Colour.navy)
                Spacer()
                if typingVoucher {
                    Text(L("pay_voucher_typing"))
                        .font(.caption)
                        .foregroundStyle(Tokens.Colour.brandAccessible)
                }
            }
            .padding(.horizontal, Tokens.Spacing.lg)
            .padding(.vertical, Tokens.Spacing.md)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Tokens.Colour.surfaceElevated)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(typingVoucher ? Tokens.Colour.brand : Tokens.Colour.divider,
                                  lineWidth: typingVoucher ? 1.5 : 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// A phone keypad. Never mirrored: digits sit where a hand expects them in either language.
    private var keypad: some View {
        let rows: [[String]] = [["1", "2", "3"], ["4", "5", "6"], ["7", "8", "9"], [".", "0", "⌫"]]
        return VStack(spacing: 4) {
            ForEach(rows, id: \.self) { row in
                HStack(spacing: 0) {
                    ForEach(row, id: \.self) { key in
                        keypadKey(key)
                    }
                }
            }
        }
        .environment(\.layoutDirection, .leftToRight)
    }

    private func keypadKey(_ key: String) -> some View {
        let disabled = key == "." && typingVoucher
        return Button {
            press(key)
        } label: {
            Group {
                if key == "⌫" {
                    Image(systemName: "delete.left")
                        .font(.system(size: 22, weight: .medium))
                } else {
                    Text(key)
                        .font(.system(size: 28, weight: .medium))
                }
            }
            .foregroundStyle(Tokens.Colour.navy)
            .frame(maxWidth: .infinity, minHeight: 56)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.3 : 1)
        .accessibilityLabel(key == "⌫" ? L("pay_delete") : key)
    }

    private func press(_ key: String) {
        if key == "⌫" {
            if typingVoucher { voucher = String(voucher.dropLast()) } else { amount = String(amount.dropLast()) }
            return
        }
        guard let character = key.first else { return }
        if typingVoucher {
            voucher = VoucherInput.press(voucher, character)
        } else {
            amount = AmountInput.press(amount, character)
        }
    }
}

/// What the keypad does to the amount: digits, one decimal point, two decimal places, no leading
/// zeros — so the text is always a number the server will read the way the person meant it.
enum AmountInput {
    /// Up to ₪999,999: more than any one payment, so a stuck key cannot run away.
    static let maxWholeDigits = 6

    static func press(_ current: String, _ key: Character) -> String {
        let dot = current.firstIndex(of: ".")
        if key == "." {
            if dot != nil { return current }
            return current.isEmpty ? "0." : current + "."
        }
        guard key.isASCII, key.isNumber else { return current }
        if let dot {
            return current.distance(from: dot, to: current.endIndex) - 1 >= 2 ? current : current + String(key)
        }
        if current == "0" { return String(key) }
        if current.count >= maxWholeDigits { return current }
        return current + String(key)
    }

    /// The amount, when it is one worth paying.
    static func value(_ text: String) -> Double? {
        guard let value = Double(text), value > 0 else { return nil }
        return value
    }

    /// Last time's amount as the keypad would have typed it: "20", "15.5", "12.25".
    static func initial(_ amount: Double?) -> String {
        guard let amount, amount > 0, amount.isFinite else { return "" }
        var text = String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), amount)
        while text.contains(".") && (text.hasSuffix("0") || text.hasSuffix(".")) { text.removeLast() }
        return (text.split(separator: ".").first?.count ?? 0) > maxWholeDigits ? "" : text
    }
}

/// A voucher code typed on the keypad: digits only. Its length is the server's business.
enum VoucherInput {
    static let minLength = 4
    private static let maxLength = 24

    static func press(_ current: String, _ key: Character) -> String {
        key.isASCII && key.isNumber && current.count < maxLength ? current + String(key) : current
    }
}
