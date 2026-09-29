import SwiftUI
import ZapFastBridge
import ZapFastCore
import ZapFastDesign

/// Creates, renames, recolours and deletes labels. Labels stay on this
/// computer, as upstream says in the same place.
struct LabelManagerSheet: View {
    let model: AppModel

    @State private var newName = ""
    @State private var newColor = ""
    @FocusState private var nameFocused: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let rules = model.labelRules
        let labels = model.chats.labels
        let full = labels.count >= Int(rules.limit)
        VStack(alignment: .leading, spacing: Metrics.m) {
            Text("Labels").font(.headline)
            Text("Labels stay on this computer. They do not reach your phone or anyone you chat with.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if full {
                Text("You have \(rules.limit) labels, the most ZapFast keeps.")
                    .font(.callout)
                    .foregroundStyle(.orange)
            } else {
                HStack(spacing: Metrics.s) {
                    ColorMenu(colors: rules.colors, selection: $newColor)
                    TextField("New label", text: limited($newName, Int(rules.nameLimit)))
                        .textFieldStyle(.roundedBorder)
                        .focused($nameFocused)
                        .onSubmit(create)
                    Button("Create", action: create)
                        .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }

            List {
                ForEach(labels, id: \.id) { label in
                    LabelRow(label: label, model: model)
                }
            }
            .listStyle(.bordered)
            .alternatingRowBackgrounds(.disabled)
            .frame(minHeight: 220)
            .overlay {
                if labels.isEmpty {
                    Text("No labels yet. Create one above, then add chats to it from their right-click menu.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding()
                }
            }

            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(Metrics.l)
        .frame(width: 400)
        .onAppear {
            newColor = rules.colors.first ?? "#3b82f6"
            nameFocused = true
        }
    }

    private func create() {
        guard !newName.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        model.createLabel(name: newName, colorHex: newColor)
        newName = ""
    }
}

/// One label: its colour and name, both changeable in place, and Delete.
private struct LabelRow: View {
    let label: LabelInfo
    let model: AppModel
    @State private var name = ""
    @State private var color = ""
    @State private var confirmingDelete = false

    var body: some View {
        HStack(spacing: Metrics.s) {
            ColorMenu(colors: model.labelRules.colors, selection: $color)
            TextField("Name", text: limited($name, Int(model.labelRules.nameLimit)))
                .textFieldStyle(.plain)
                .onSubmit(save)
            Button("Delete", systemImage: "trash") { confirmingDelete = true }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Delete this label. Its chats keep their messages.")
        }
        .onAppear {
            name = label.name
            color = label.colorHex
        }
        .onChange(of: color) { save() }
        .confirmationDialog("Delete “\(label.name)”?", isPresented: $confirmingDelete) {
            Button("Delete Label", role: .destructive) { model.deleteLabel(label) }
        } message: {
            Text("Its chats keep their messages.")
        }
    }

    private func save() {
        guard !color.isEmpty else { return }
        model.updateLabel(label, name: name, colorHex: color)
    }
}

/// A colour well that opens the preset colours.
private struct ColorMenu: View {
    let colors: [String]
    @Binding var selection: String

    var body: some View {
        Menu {
            ForEach(colors, id: \.self) { hex in
                Toggle(isOn: Binding(get: { hex == selection }, set: { if $0 { selection = hex } })) {
                    Label {
                        Text(ColorSwatch.name(hex: hex))
                    } icon: {
                        ColorSwatch.image(hex: hex)
                    }
                }
            }
        } label: {
            Circle().fill(Color(hex: selection)).frame(width: 14, height: 14)
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(Text(ColorSwatch.name(hex: selection)))
    }
}

/// Stops typing at `limit` characters.
private func limited(_ text: Binding<String>, _ limit: Int) -> Binding<String> {
    Binding(get: { text.wrappedValue }, set: { text.wrappedValue = String($0.prefix(limit)) })
}
