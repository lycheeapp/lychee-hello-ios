import SwiftUI
import Observation

/// New-user onboarding — first and last name only (decision D6).
///
/// Deliberately **not** collected: gender and identity number. The backend defaults gender and the
/// identity-number requirement is commented out in `signUp`; asking for either here would be
/// friction for data Hello does not use.
@Observable
@MainActor
public final class ProfileSetupModel {

    public var firstName: String = "" { didSet { errorMessage = nil } }
    public var lastName: String = "" { didSet { errorMessage = nil } }
    public private(set) var isSaving = false
    public private(set) var errorMessage: String?

    private let repository: HelloRepositoryProtocol

    public init(repository: HelloRepositoryProtocol) {
        self.repository = repository
    }

    public var canSubmit: Bool {
        !isSaving
            && firstName.trimmingCharacters(in: .whitespaces).count >= 2
            && lastName.trimmingCharacters(in: .whitespaces).count >= 2
    }

    public func submit(coordinator: SessionCoordinator) async {
        guard canSubmit else { return }
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }

        do {
            let user = try await repository.updateProfile(
                firstName: firstName.trimmingCharacters(in: .whitespaces),
                lastName: lastName.trimmingCharacters(in: .whitespaces)
            )
            await coordinator.didCompleteOnboarding(user)
        } catch let error as APIError {
            // The backend enforces full-name uniqueness (`ensureFullNameIsUnique`), so a common
            // name can legitimately be rejected. Generic copy would leave the user stuck retrying
            // the same value, so the guidance is explicit.
            errorMessage = error.code == .internalError || error.code == .unknown
                ? L("profile_error_name")
                : error.userMessage
        } catch {
            errorMessage = L("error_generic")
        }
    }
}

struct ProfileSetupView: View {

    @Environment(SessionCoordinator.self) private var coordinator
    @State private var model: ProfileSetupModel
    @FocusState private var focusedField: Field?

    private enum Field { case first, last }

    init(model: ProfileSetupModel) {
        _model = State(initialValue: model)
    }

    var body: some View {
        ZStack {
            Tokens.Colour.surface.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: Tokens.Spacing.xl) {
                    // No "What should we call you?" heading: the line below says it, and the fields
                    // are the screen.
                    Text(L("profile_subtitle_ios"))
                        .font(Tokens.Typography.body)
                        .foregroundStyle(Tokens.Colour.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, Tokens.Spacing.xxl)

                    field(title: L("profile_first_name"), text: $model.firstName, field: .first, content: .givenName)
                    field(title: L("profile_last_name"), text: $model.lastName, field: .last, content: .familyName)

                    if let error = model.errorMessage {
                        Text(error)
                            .font(Tokens.Typography.caption)
                            .foregroundStyle(Tokens.Colour.danger)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    LHPrimaryButton(
                        title: L("common_continue"),
                        trailingSystemImage: "arrow.right",
                        isLoading: model.isSaving,
                        isEnabled: model.canSubmit
                    ) {
                        Task { await model.submit(coordinator: coordinator) }
                    }
                }
                .padding(.horizontal, Tokens.Spacing.gutter)
                .padding(.bottom, Tokens.Spacing.xxl)
            }
        }
        .onAppear { focusedField = .first }
    }

    private func field(
        title: String,
        text: Binding<String>,
        field: Field,
        content: UITextContentType
    ) -> some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.sm) {
            Text(title)
                .font(Tokens.Typography.callout)
                .foregroundStyle(Tokens.Colour.textSecondary)

            TextField("", text: text)
                .textContentType(content)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.words)
                .font(Tokens.Typography.headline)
                .focused($focusedField, equals: field)
                .submitLabel(field == .first ? .next : .done)
                .onSubmit { focusedField = field == .first ? .last : nil }
                .padding(.horizontal, Tokens.Spacing.lg)
                .frame(minHeight: 56)
                .background(Tokens.Colour.surfaceElevated)
                .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.field, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: Tokens.Radius.field, style: .continuous)
                        .stroke(Tokens.Colour.divider, lineWidth: 1)
                )
                .accessibilityLabel(title)
        }
    }
}
