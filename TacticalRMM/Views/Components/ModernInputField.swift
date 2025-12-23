import SwiftUI

struct ModernInputField: View {
    enum FieldKind { case text, secure }

    let title: String
    let placeholder: String
    @Binding var text: String
    var kind: FieldKind = .text
    var keyboard: UIKeyboardType = .default
    var focus: FocusState<Bool>.Binding? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Color.white.opacity(0.6))
                .kerning(1.2)
            Group {
                switch kind {
                case .text:
                    if let focus {
                        TextField(placeholder, text: $text)
                            .textInputAutocapitalization(.never)
                            .disableAutocorrection(true)
                            .platformKeyboardType(keyboard)
                            .focused(focus)
                    } else {
                        TextField(placeholder, text: $text)
                            .textInputAutocapitalization(.never)
                            .disableAutocorrection(true)
                            .platformKeyboardType(keyboard)
                    }
                case .secure:
                    if let focus {
                        SecureField(placeholder, text: $text)
                            .textInputAutocapitalization(.never)
                            .disableAutocorrection(true)
                            .focused(focus)
                    } else {
                        SecureField(placeholder, text: $text)
                            .textInputAutocapitalization(.never)
                            .disableAutocorrection(true)
                    }
                }
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 14)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.white.opacity(0.05))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(Color.white.opacity(0.08), lineWidth: 1)
                    )
            )
        }
    }
}
