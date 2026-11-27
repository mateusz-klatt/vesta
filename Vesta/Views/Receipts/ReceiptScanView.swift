import Photos
import PhotosUI
import SwiftUI

/// Add a paper receipt to hestia's budget: scan (or pick a photo, or paste Live
/// Text) → check the recognised text → review what hestia parsed → confirm.
/// Only the redacted text is sent; the photo never leaves the phone.
struct ReceiptScanView: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var pairingPresentation = ReceiptPairingPresentation()
    /// Owned by the presenter, which calls ``ReceiptFlow/abandon()`` when the sheet closes.
    let flow: ReceiptFlow

    var body: some View {
        NavigationStack {
            Group {
                switch flow.step {
                case .capture: ReceiptCaptureStep(flow: flow)
                case .edit: ReceiptEditStep(flow: flow)
                case .review: ReceiptReviewStep(flow: flow)
                case .done: ReceiptDoneStep { dismiss() }
                }
            }
            .disabled(flow.isBusy)
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle("Add receipt")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if flow.step != .done {
                        Button("Cancel") { dismiss() }
                            .disabled(flow.isBusy)
                    }
                }
                if flow.step != .done && (flow.error?.requiresPairing == true || app.receiptPairing.status == .pairAgain) {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Pair again") { pairingPresentation.present(in: app) }
                            .disabled(flow.isBusy)
                    }
                }
            }
            .overlay {
                if flow.isBusy { ProgressView().controlSize(.large) }
            }
        }
        // Cleanup runs on any dismissal; this only guards review edits from a stray swipe.
        .interactiveDismissDisabled(flow.step == .review)
        .receiptPairingSheet($pairingPresentation, app: app)
    }
}

// MARK: - Steps

private struct ReceiptCaptureStep: View {
    @Bindable var flow: ReceiptFlow
    @State private var cameraPresentation: ReceiptCamera.Presentation?
    @State private var capturedPhoto: UIImage?
    @State private var singlePhoto: PhotosPickerItem?
    @State private var showPhotoPicker = false
    @State private var pickerSelection: [PhotosPickerItem] = []
    @State private var isStaging = false
    @State private var photoOrder = ReceiptPhotoOrder()

    var body: some View {
        let selectedPhotos = pickerSelection
        Form {
            if isStaging {
                stagedPhotos
            } else {
                captureOptions
            }
            ReceiptErrorSection(error: flow.error)
        }
        .disabled(!selectedPhotos.isEmpty)
        .overlay {
            if !selectedPhotos.isEmpty { ProgressView().controlSize(.large) }
        }
        .fullScreenCover(item: $cameraPresentation, onDismiss: acceptCapturedPhoto) { presentation in
            ReceiptCamera { image in
                guard cameraPresentation?.id == presentation.id else { return }
                capturedPhoto = image
                cameraPresentation = nil
            }
            .ignoresSafeArea()
        }
        .onChange(of: singlePhoto) { _, item in
            guard let item else { return }
            singlePhoto = nil
            Task {
                await flow.recognize(pageCount: 1) { _ in try await ReceiptCapturePhoto.loadImage(from: item) }
            }
        }
        .photosPicker(isPresented: $showPhotoPicker, selection: $pickerSelection,
                      maxSelectionCount: nil, selectionBehavior: .ordered, matching: .images,
                      photoLibrary: .shared())
        .task(id: selectedPhotos) { await acceptGalleryBatch(selectedPhotos) }
    }

    private var captureOptions: some View {
        Section {
            cameraButton
            PhotosPicker(selection: $singlePhoto, matching: .images) {
                Label("Choose a photo", systemImage: "photo")
            }
            Button {
                flow.useText(UIPasteboard.general.string ?? "")
            } label: {
                Label("Paste text", systemImage: "doc.on.clipboard")
            }
            Button { isStaging = true } label: {
                Label("Scan a long receipt", systemImage: "square.stack")
            }
        } footer: {
            Text("Text is read on this iPhone. Only the text is sent to your server, with card numbers removed. The photo is not saved or uploaded.")
        }
    }

    @ViewBuilder
    private var stagedPhotos: some View {
        Section {
            if photoOrder.photos.isEmpty {
                cameraButton
                choosePhotosButton
            } else {
                ForEach(Array(photoOrder.photos.enumerated()), id: \.element.id) { index, photo in
                    photoRow(photo, at: index)
                }
                Menu {
                    cameraButton
                    choosePhotosButton
                } label: {
                    Label("Add another photo", systemImage: "plus")
                }
                Button("Remove last photo", role: .destructive) {
                    photoOrder.removeLast()
                    flow.error = nil
                }
            }
        } footer: {
            Text("Photograph the receipt from top to bottom. Overlap each photo with the previous one by about 20–30%.")
        }
        Section {
            if photoOrder.photos.isEmpty {
                Button("Start over") {
                    flow.error = nil
                    isStaging = false
                }
            } else {
                Button("Done", action: recognizeStagedPhotos)
            }
        }
    }

    @ViewBuilder
    private var cameraButton: some View {
        if ReceiptCamera.isSupported {
            Button {
                if cameraPresentation == nil { cameraPresentation = .init() }
            } label: {
                Label("Scan receipt", systemImage: "doc.viewfinder")
            }
        }
    }

    private var choosePhotosButton: some View {
        Button { showPhotoPicker = true } label: {
            Label("Choose photos", systemImage: "photo.on.rectangle")
        }
    }

    private func photoRow(_ photo: ReceiptCapturePhoto, at index: Int) -> some View {
        HStack {
            Image(uiImage: photo.thumbnail)
                .resizable()
                .scaledToFit()
                .frame(width: 48, height: 60)
                .accessibilityHidden(true)
            Text("Photo \(index + 1)")
            Spacer()
            if photoOrder.photos.count > 1 {
                Button {
                    photoOrder.move(photo.id, by: -1)
                } label: {
                    Label("Move photo up", systemImage: "chevron.up")
                        .labelStyle(.iconOnly)
                        .frame(minWidth: 44, minHeight: 44)
                }
                .disabled(index == 0)
                Button {
                    photoOrder.move(photo.id, by: 1)
                } label: {
                    Label("Move photo down", systemImage: "chevron.down")
                        .labelStyle(.iconOnly)
                        .frame(minWidth: 44, minHeight: 44)
                }
                .disabled(index == photoOrder.photos.count - 1)
            }
        }
        .buttonStyle(.borderless)
    }

    private func acceptCapturedPhoto() {
        guard let photo = capturedPhoto else { return }
        capturedPhoto = nil
        if isStaging {
            do {
                let staged = try autoreleasepool { try ReceiptCapturePhoto(camera: photo) }
                photoOrder.append([staged])
                flow.error = nil
            } catch {
                flow.error = .photoUnavailable
            }
            return
        }
        Task {
            await flow.recognize(pageCount: 1) { _ in
                guard let image = photo.uprightReceiptImage else { throw ReceiptError.photoUnavailable }
                return image
            }
        }
    }

    private func acceptGalleryBatch(_ items: [PhotosPickerItem]) async {
        guard !items.isEmpty, !Task.isCancelled else { return }
        defer { if !Task.isCancelled { pickerSelection = [] } }
        flow.error = nil
        do {
            var identifiers = Set(photoOrder.photos.compactMap(\.libraryIdentifier))
            var staged: [ReceiptCapturePhoto] = []
            for item in items {
                try Task.checkCancellation()
                if let id = item.itemIdentifier, !identifiers.insert(id).inserted { continue }
                staged.append(try await ReceiptCapturePhoto(library: item))
            }
            try Task.checkCancellation()
            photoOrder.append(staged)
        } catch {
            guard !Task.isCancelled, !APIError.isCancellation(error),
                  (error as? CocoaError)?.code != .userCancelled else { return }
            flow.error = .photoUnavailable
        }
    }

    private func recognizeStagedPhotos() {
        let pages = photoOrder.photos
        Task {
            await flow.recognize(pageCount: pages.count) { index in
                try await pages[index].loadImage()
            }
        }
    }
}

private struct ReceiptEditStep: View {
    @Bindable var flow: ReceiptFlow

    var body: some View {
        Form {
            Section {
                TextEditor(text: $flow.text)
                    .font(.system(.footnote, design: .monospaced))
                    .frame(minHeight: 320)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            } header: {
                Text("Recognised text")
            } footer: {
                if !VisionReceiptRecognizer.supportsPolish {
                    Text("This iPhone can’t read Polish characters yet — check ą, ę, ł, ż in product names.")
                } else {
                    Text("Fix anything misread, then send it to your server to read the receipt.")
                }
                if let message = flow.overlapReviewMessage {
                    Text(message).foregroundStyle(Theme.textSecondary)
                }
            }
            ReceiptErrorSection(error: flow.error)
            Section {
                Button("Read receipt") { Task { await flow.send() } }
                    .disabled(flow.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Start over", role: .destructive) { flow.startOver() }
            }
        }
    }
}

private struct ReceiptReviewStep: View {
    @Bindable var flow: ReceiptFlow

    var body: some View {
        Form {
            Section("Receipt") {
                TextField("Shop", text: $flow.form.shopName)
                    .onSubmit { flow.form.shopName = PANRedactor.redact(flow.form.shopName) }
                TextField("NIP", text: $flow.form.nip).keyboardType(.numberPad)
                if flow.form.day != nil {
                    DatePicker("Date", selection: dayBinding, displayedComponents: .date)
                } else {
                    Button("Set date") { flow.form.day = ReceiptDay(date: .now) }
                        .foregroundStyle(.red)
                }
                TextField("Time (HH:MM)", text: $flow.form.time).keyboardType(.numbersAndPunctuation)
                Picker("Type", selection: $flow.form.kind) {
                    Text("Purchase").tag(ReceiptConfirmRequest.ReceiptKindPayload.purchase)
                    Text("Refund").tag(ReceiptConfirmRequest.ReceiptKindPayload.refund)
                }
                Picker("Payment", selection: $flow.form.payment) {
                    Text("Card").tag(ReceiptConfirmRequest.PaymentMethodPayload.card)
                    Text("BLIK").tag(ReceiptConfirmRequest.PaymentMethodPayload.blik)
                    Text("Cash").tag(ReceiptConfirmRequest.PaymentMethodPayload.cash)
                    Text("Mixed").tag(ReceiptConfirmRequest.PaymentMethodPayload.mixed)
                    Text("Unknown").tag(ReceiptConfirmRequest.PaymentMethodPayload.unknown)
                }
                LabeledContent("Total") {
                    TextField("0.00", text: $flow.form.total)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                    Text(verbatim: flow.form.currency).foregroundStyle(Theme.textSecondary)
                }
            }

            Section {
                ForEach(flow.form.lines, id: \.lineNo) { line in
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: line.rawName)
                            Text(verbatim: "\(line.quantity) × \(line.unitPriceRaw ?? "—")")
                                .font(.caption).foregroundStyle(Theme.textSecondary)
                        }
                        Spacer()
                        Text(verbatim: line.netLineTotal).monospacedDigit()
                    }
                }
            } header: {
                Text("Items (\(flow.form.lines.count))")
            } footer: {
                if let message = flow.overlapReviewMessage {
                    Text(message).foregroundStyle(Theme.textSecondary)
                }
                if let adjustment = flow.form.totalAdjustment {
                    Text(adjustment.message).foregroundStyle(Theme.textSecondary)
                }
            }

            if flow.canMatchReceipts && flow.form.canLink {
                Section {
                    if flow.form.matchFieldsEdited {
                        Text("Shop or NIP changed, so these matches no longer apply. Save without a link, or go back and read the text again.")
                            .font(.footnote).foregroundStyle(Theme.textSecondary)
                    } else {
                        Picker("Bank transaction", selection: $flow.form.candidate) {
                            Text("Don’t link").tag(ReceiptForm.CandidateID?.none)
                            ForEach(flow.candidates, id: \.candidateToken) { candidate in
                                Text(verbatim: Self.describe(candidate))
                                    .tag(ReceiptForm.CandidateID?.some(.init(candidate)))
                            }
                        }
                        .pickerStyle(.inline)
                        .labelsHidden()
                    }
                } header: {
                    Text("Bank transaction")
                } footer: {
                    if flow.candidates.isEmpty {
                        Text("No matching transaction yet. You can save the receipt without one.")
                    }
                }
            }

            ReceiptErrorSection(error: flow.form.confirmLineError ?? flow.error)

            Section {
                Button("Save receipt") { Task { await flow.confirm() } }
                    .disabled(!flow.form.isValid)
                Button("Back to text") { Task { await flow.backToEdit() } }
            }
        }
    }

    private var dayBinding: Binding<Date> {
        Binding(
            get: { flow.form.day?.date ?? .now },
            set: { flow.form.day = ReceiptDay(date: $0) }
        )
    }

    private static func describe(_ candidate: ReceiptCandidate) -> String {
        let day = candidate.transactionDate ?? candidate.bookingDate ?? candidate.valueDate ?? "—"
        let merchant = candidate.merchantTokenHit ? " ✓" : ""
        return "\(day) · \(candidate.amount) \(candidate.currency)\(merchant)"
    }
}

private struct ReceiptDoneStep: View {
    let close: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 56)).foregroundStyle(.green)
            Text("Receipt saved").font(.title2.bold())
            Button("Done", action: close).buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ReceiptErrorSection: View {
    let error: ReceiptError?

    var body: some View {
        if let error {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text(error.title).font(.headline)
                    Text(error.message).font(.subheadline).foregroundStyle(Theme.textSecondary)
                    if let technical = error.technical {
                        Text(verbatim: technical).font(.caption.monospaced()).foregroundStyle(Theme.textSecondary)
                    }
                }
            }
        }
    }
}
