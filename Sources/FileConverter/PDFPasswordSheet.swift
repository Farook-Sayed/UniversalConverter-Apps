import SwiftUI
import ConverterCore

/// Asks for the password of the PDFs in the list that have one. One password is tried on all of them, so files that
/// share a password need it only once. Nothing is stored: the password is kept in memory until the app quits.
struct PDFPasswordSheet: View {
    @Environment(AppModel.self) private var model
    @State private var password = ""
    @State private var working = false
    @FocusState private var focused: Bool

    private var names: [String] {
        model.items.filter { $0.lock == .needsPassword }.map { $0.file.url.lastPathComponent }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "lock.doc.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(names.count == 1 ? "This PDF has a password" : "\(names.count) PDFs have a password")
                        .font(.headline)
                    Text("Enter it to open them. If several files share one password, you only type it once.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                ForEach(names.prefix(5), id: \.self) { name in
                    Label(name, systemImage: "doc")
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if names.count > 5 {
                    Text("and \(names.count - 5) more").font(.caption).foregroundStyle(.secondary)
                }
            }

            SecureField("Password", text: $password)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit(unlock)
                .disabled(working)

            if let message = model.passwordMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("The file is opened on this Mac. The password is not saved or sent anywhere. The original file is not changed.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Not Now") { model.stopAskingForPassword() }
                    .keyboardShortcut(.cancelAction)
                Button("Open") { unlock() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(password.isEmpty || working)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear { focused = true }
    }

    private func unlock() {
        guard !password.isEmpty, !working else { return }
        working = true
        Task {
            await model.unlockPDFs(password: password)
            password = ""
            working = false
            focused = true
        }
    }
}
