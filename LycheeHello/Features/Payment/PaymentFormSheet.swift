import SwiftUI

/// Structured payment form for both quick actions.
///
/// One view with a mode rather than two near-identical sheets: the only difference is whether a
/// voucher field appears, and duplicating the payee/amount handling is how the two would drift.
/// Either way the server composes the canonical command, so both share the free-text grammar.
struct PaymentFormSheet: View {

    enum Mode: Identifiable {
        case balance
        case voucher

        var id: Self { self }

        var title: String {
            switch self {
            case .balance: return "Pay from balance"
            case .voucher: return "Use a voucher"
            }
        }

        var needsVoucher: Bool { self == .voucher }
    }

    @Environment(\.dismiss) private var dismiss
    @State private var payee = ""
    @State private var voucherCode = ""
    @State private var amountText = ""

    let mode: Mode
    let onSubmit: (String, String?, Double) -> Void

    /// Voucher codes are 6 characters (decision U1).
    private let voucherLength = 6

    private var amount: Double? { Double(amountText.replacingOccurrences(of: ",", with: ".")) }

    private var canSubmit: Bool {
        let hasPayee = !payee.trimmingCharacters(in: .whitespaces).isEmpty
        let hasVoucher = !mode.needsVoucher || voucherCode.count == voucherLength
        return hasPayee && hasVoucher && (amount ?? 0) > 0
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Pay to") {
                    TextField("Payee code or phone number", text: $payee)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.characters)
                }
                if mode.needsVoucher {
                    Section("Voucher") {
                        TextField("\(voucherLength)-character code", text: $voucherCode)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.characters)
                            .onChange(of: voucherCode) { _, value in
                                voucherCode = String(value.prefix(voucherLength))
                            }
                    }
                }
                Section("Amount") {
                    HStack {
                        Text(Money.symbol).foregroundStyle(Tokens.Colour.textSecondary)
                        TextField("0", text: $amountText).keyboardType(.decimalPad)
                    }
                }
            }
            .navigationTitle(mode.title)
            .navigationBarTitleDisplayMode(.inline)
            // The amount field uses decimalPad — no return key, so it needs an explicit escape.
            .keyboardDoneToolbar()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Continue") {
                        if let amount {
                            onSubmit(
                                payee.trimmingCharacters(in: .whitespaces),
                                mode.needsVoucher ? voucherCode : nil,
                                amount
                            )
                        }
                        dismiss()
                    }
                    .disabled(!canSubmit)
                }
            }
        }
    }
}
