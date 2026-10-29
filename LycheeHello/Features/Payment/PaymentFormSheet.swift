import SwiftUI

/// The guided forms behind "+": the structured alternative to typing a WhatsApp command.
///
/// One view with a mode rather than near-identical sheets: duplicating the amount handling is how
/// they would drift. Whatever the mode, the server composes the canonical command from the fields
/// and runs the same parser as free text — `payee [voucher] amount`, `<IBAN> [amount]`,
/// `topup <phone> <amount> <pin>` — so a form can never accept something a message would not.
struct PaymentFormSheet: View {

    enum Mode: Identifiable {
        case balance
        case voucher
        /// Money to a bank account (WhatsApp's `<IBAN> [amount]`).
        case withdraw
        /// An operator's top-up for a customer (WhatsApp's `topup <phone> <amount> <pin>`).
        case topUp

        var id: Self { self }

        var title: String {
            switch self {
            case .balance: return "Pay from balance"
            case .voucher: return "Use a voucher"
            case .withdraw: return "Withdraw to bank"
            case .topUp: return "Top up a customer"
            }
        }

        var needsVoucher: Bool { self == .voucher }

        /// A suspended wallet cannot pay or withdraw. A top-up is paid from the operator's top-up
        /// balance, not their wallet, so it is not gated on it — as on WhatsApp.
        var needsPayableWallet: Bool { self != .topUp }
    }

    /// What the form asks the server to do.
    enum Submission {
        case payment(payee: String, voucherCode: String?, amount: Double)
        case withdrawal(iban: String, amount: Double?)
        case topUp(recipientPhone: String, amount: Double, pin: String)
    }

    @Environment(\.dismiss) private var dismiss
    @State private var payee = ""
    @State private var voucherCode = ""
    @State private var amountText = ""
    @State private var iban = ""
    @State private var phone = ""
    @State private var pin = ""

    let mode: Mode
    let onSubmit: (Submission) -> Void

    /// Voucher codes are 6 characters (decision U1).
    private let voucherLength = 6

    private var amount: Double? { Double(amountText.replacingOccurrences(of: ",", with: ".")) }

    /// IBANs are handled compact platform-wide; spaces are a reading aid only.
    private var compactIban: String {
        iban.replacingOccurrences(of: " ", with: "").uppercased()
    }

    private var canSubmit: Bool {
        switch mode {
        case .balance, .voucher:
            let hasPayee = !payee.trimmingCharacters(in: .whitespaces).isEmpty
            let hasVoucher = !mode.needsVoucher || voucherCode.count == voucherLength
            return hasPayee && hasVoucher && (amount ?? 0) > 0
        case .withdraw:
            // Shape only — the server validates the IBAN properly and says what is wrong with it.
            // An empty amount is allowed: it withdraws the whole balance.
            return compactIban.count >= 15 && (amountText.isEmpty || (amount ?? 0) > 0)
        case .topUp:
            return phone.filter(\.isNumber).count >= 9 && (amount ?? 0) > 0 && (4...8).contains(pin.count)
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                switch mode {
                case .balance, .voucher:
                    paymentFields
                case .withdraw:
                    withdrawalFields
                case .topUp:
                    topUpFields
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
                        if let submission {
                            onSubmit(submission)
                        }
                        dismiss()
                    }
                    .disabled(!canSubmit)
                }
            }
        }
    }

    @ViewBuilder
    private var paymentFields: some View {
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
        amountSection(footer: nil)
    }

    @ViewBuilder
    private var withdrawalFields: some View {
        Section {
            TextField("PS92 PALS 0000 …", text: $iban)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.characters)
                .font(.body.monospaced())
        } header: {
            Text("IBAN")
        } footer: {
            Text("The bank account the money goes to. It must be in your name.")
        }
        amountSection(footer: "Leave empty to withdraw your whole available balance. A fee may apply; you will see it before you confirm.")
    }

    @ViewBuilder
    private var topUpFields: some View {
        Section("Customer") {
            TextField("Mobile number", text: $phone)
                .keyboardType(.phonePad)
                .textContentType(.telephoneNumber)
        }
        amountSection(footer: nil)
        Section {
            SecureField("PIN", text: $pin)
                .keyboardType(.numberPad)
                .onChange(of: pin) { _, value in
                    pin = String(value.filter(\.isNumber).prefix(8))
                }
        } header: {
            Text("Your top-up PIN")
        } footer: {
            Text("Your PIN is checked and never stored or shown in the chat.")
        }
    }

    private func amountSection(footer: String?) -> some View {
        Section {
            HStack {
                Text(Money.symbol).foregroundStyle(Tokens.Colour.textSecondary)
                TextField("0", text: $amountText).keyboardType(.decimalPad)
            }
        } header: {
            Text("Amount")
        } footer: {
            if let footer {
                Text(footer)
            }
        }
    }

    private var submission: Submission? {
        switch mode {
        case .balance, .voucher:
            guard let amount else { return nil }
            return .payment(
                payee: payee.trimmingCharacters(in: .whitespaces),
                voucherCode: mode.needsVoucher ? voucherCode : nil,
                amount: amount
            )
        case .withdraw:
            return .withdrawal(iban: compactIban, amount: amountText.isEmpty ? nil : amount)
        case .topUp:
            guard let amount else { return nil }
            return .topUp(recipientPhone: phone.filter { $0.isNumber || $0 == "+" }, amount: amount, pin: pin)
        }
    }
}
