import ImageIO
import PhotosUI
import SwiftUI
import Vision

#if os(iOS)
import AVFoundation
import UIKit
#endif

struct QuickFocusPhotoImportView: View {
    let onImport: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var photo: PhotosPickerItem?
    @State private var input: Input?
    @State private var recognizedText = ""
    @State private var errorMessage: String?
    @State private var isRequestingCamera = false
    #if os(iOS)
    @State private var showingCamera = false
    #endif

    private enum Input: Equatable {
        case photo(PhotosPickerItem)
        case camera(Data)
    }

    var body: some View {
        let tasks = QuickFocusImportLine.parse(recognizedText)
        let dailyCount = tasks.filter(\.isDaily).count

        NavigationStack {
            Form {
                Section {
                    #if os(iOS)
                    if UIImagePickerController.isSourceTypeAvailable(.camera) {
                        Button("Hacer foto", systemImage: "camera") {
                            isRequestingCamera = true
                        }
                        .disabled(input != nil || isRequestingCamera)
                    }
                    #endif
                    PhotosPicker(selection: $photo, matching: .images) {
                        Label("Elegir de Fotos", systemImage: "photo")
                    }
                    .disabled(input != nil || isRequestingCamera)

                    if input != nil {
                        ProgressView("Leyendo la foto…")
                    }
                    if let errorMessage {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                    }
                } footer: {
                    Text("Escribe una tarea por línea. Si termina en «siempre», se repetirá cada día.")
                }

                Section {
                    TextEditor(text: $recognizedText)
                        .accessibilityLabel("Texto de las tareas")
                        .frame(minHeight: 160)
                        .disabled(input != nil)
                } header: {
                    Text("Revisa el texto antes de importar")
                } footer: {
                    Text("\(tasks.count - dailyCount) de una vez · \(dailyCount) diarias")
                }
            }
            .navigationTitle("Importar tareas")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Importar") {
                        onImport(recognizedText)
                        dismiss()
                    }
                    .disabled(tasks.isEmpty || input != nil)
                }
            }
        }
        .onChange(of: photo) { _, item in
            if let item {
                input = .photo(item)
                photo = nil
            }
        }
        #if os(iOS)
        .task(id: isRequestingCamera) {
            if isRequestingCamera {
                await openCamera()
            }
        }
        .fullScreenCover(isPresented: $showingCamera) {
            QuickFocusCameraView { image in
                showingCamera = false
                guard let image else { return }
                guard let data = image.jpegData(compressionQuality: 0.9) else {
                    errorMessage = "No se pudo abrir la foto. Prueba con otra imagen."
                    return
                }
                input = .camera(data)
            }
            .ignoresSafeArea()
        }
        #endif
        .task(id: input) {
            guard let input else { return }
            await read(input)
        }
    }

    #if os(iOS)
    private func openCamera() async {
        defer { isRequestingCamera = false }
        errorMessage = nil
        // iOS terminates the process if camera access is requested without this key.
        guard let description = Bundle.main.object(forInfoDictionaryKey: "NSCameraUsageDescription") as? String,
              !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            errorMessage = "Esta versión de Agenda no tiene configurado el acceso a la cámara. Puedes elegir una imagen de Fotos."
            return
        }

        let status = AVCaptureDevice.authorizationStatus(for: .video)
        let authorized = if status == .notDetermined {
            await AVCaptureDevice.requestAccess(for: .video)
        } else {
            status == .authorized
        }
        guard !Task.isCancelled else { return }
        guard authorized else {
            errorMessage = "Permite el acceso a la cámara en Ajustes o elige una imagen de Fotos."
            return
        }
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
            errorMessage = "La cámara no está disponible. Puedes elegir una imagen de Fotos."
            return
        }
        showingCamera = true
    }
    #endif

    private func read(_ source: Input) async {
        errorMessage = nil
        do {
            let data: Data
            switch source {
            case .photo(let item):
                guard let loadedData = try await item.loadTransferable(type: Data.self) else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                data = loadedData
            case .camera(let capturedData):
                data = capturedData
            }

            try Task.checkCancellation()
            let text = try await Task.detached(priority: .userInitiated) {
                try Self.recognizeText(in: data)
            }.value
            try Task.checkCancellation()
            if text.isEmpty {
                errorMessage = "No se detectó texto. Prueba con una foto más nítida."
            } else {
                recognizedText = text
            }
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = "No se pudo leer la foto. Prueba con otra imagen."
        }
        input = nil
    }

    private nonisolated static func recognizeText(in data: Data) throws -> String {
        guard let image = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString: Any]
        let orientationValue = properties?[kCGImagePropertyOrientation] as? UInt32 ?? 1
        let orientation = CGImagePropertyOrientation(rawValue: orientationValue) ?? .up
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["es-ES", "en-US"]
        request.usesLanguageCorrection = true
        try VNImageRequestHandler(data: data, orientation: orientation).perform([request])

        return (request.results ?? [])
            .sorted { $0.boundingBox.midY > $1.boundingBox.midY }
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: "\n")
    }
}

#if os(iOS)
private struct QuickFocusCameraView: UIViewControllerRepresentable {
    let onFinish: (UIImage?) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let controller = UIImagePickerController()
        controller.sourceType = .camera
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onFinish: onFinish)
    }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onFinish: (UIImage?) -> Void

        init(onFinish: @escaping (UIImage?) -> Void) {
            self.onFinish = onFinish
        }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            onFinish(info[.originalImage] as? UIImage)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            onFinish(nil)
        }
    }
}
#endif
