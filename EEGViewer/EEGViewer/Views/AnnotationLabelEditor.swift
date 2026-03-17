// AnnotationLabelEditor.swift
// Sheet for managing annotation label types.

import SwiftUI

struct AnnotationLabelEditor: View {
    @ObservedObject var store: AnnotationStore
    @Environment(\.dismiss) private var dismiss
    @State private var newLabelName = ""

    var body: some View {
        NavigationStack {
            List {
                ForEach($store.labels) { $label in
                    HStack {
                        ColorPicker("", selection: Binding(
                            get: { label.color.color },
                            set: { label.color = CodableColor($0) }
                        ))
                        .labelsHidden()
                        .frame(width: 30)

                        TextField("Label name", text: $label.name)
                            .textFieldStyle(.roundedBorder)

                        Picker("", selection: $label.analysisMode) {
                            Text("Exclude").tag(AnnotationLabel.AnalysisMode.exclude)
                            Text("Separate").tag(AnnotationLabel.AnalysisMode.analyzeSeparately)
                        }
                        .pickerStyle(.menu)
                        .frame(width: 110)
                    }
                }
                .onDelete { indices in
                    // Cascade: remove any annotations referencing deleted labels
                    for index in indices {
                        store.removeAnnotations(forLabel: store.labels[index].id)
                    }
                    store.labels.remove(atOffsets: indices)
                    store.save()
                }

                // Add new label row
                HStack {
                    TextField("New label name", text: $newLabelName)
                        .textFieldStyle(.roundedBorder)
                    Button {
                        guard !newLabelName.isEmpty else { return }
                        store.labels.append(AnnotationLabel(
                            name: newLabelName,
                            color: CodableColor(red: 0.3, green: 0.5, blue: 0.9),
                            analysisMode: .exclude
                        ))
                        newLabelName = ""
                        store.save()
                    } label: {
                        Image(systemName: "plus.circle.fill")
                    }
                    .disabled(newLabelName.isEmpty)
                }
            }
            .navigationTitle("Annotation Labels")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        store.save()
                        dismiss()
                    }
                }
            }
        }
    }
}
