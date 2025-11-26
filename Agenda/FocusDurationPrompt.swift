import SwiftUI

struct FocusDurationPrompt: View {
    @Binding var isPresented: Bool
    @State private var minutesString: String = ""
    var onConfirm: (Int?) -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text("Duración estimada")
                .font(.headline)
            TextField("Minutos", text: $minutesString)
                .keyboardType(.numberPad)
                .textFieldStyle(.roundedBorder)
            HStack {
                Button("Sin estimación") {
                    onConfirm(nil)
                    isPresented = false
                }
                Spacer()
                Button("Guardar") {
                    let value = Int(minutesString)
                    onConfirm(value)
                    isPresented = false
                }
                .disabled(!(Int(minutesString) ?? 0 > 0))
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(.systemBackground))
        )
        .shadow(radius: 8)
        .frame(maxWidth: 300)
    }
}
