import AppKit
import SwiftUI

struct LargeFilesView: View {
    @ObservedObject var store: LargeFilesStore

    var body: some View {
        VStack(alignment: .leading, spacing: DS.sm) {
            HStack(spacing: DS.sm) {
                Text("Ficheiros grandes").font(DS.body.weight(.medium))
                Spacer(minLength: DS.sm)
                if store.scanning {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Procurar") { Task { await store.scan() } }
                        .controlSize(.small)
                }
            }
            Picker("", selection: $store.minSize) {
                ForEach(LargeFilesRules.sizes, id: \.self) { s in Text("≥ " + Fmt.diskShort(s)).tag(s) }
            }
            .pickerStyle(.segmented).labelsHidden()
            Toggle("Só os sem uso há mais de 6 meses", isOn: $store.onlyOld).toggleStyle(.checkbox).font(DS.meta)
            if store.scannedAt == nil && !store.scanning {
                note("Na tua pasta pessoal, sem a Library nem o interior das apps.",
                     more: "Procura na tua pasta pessoal, sem a Library nem o interior das apps. O macOS pode pedir acesso a algumas pastas.")
            } else if store.scanning {
                note("A procurar… pode demorar um pouco.")
            } else if store.shown.isEmpty {
                note(String(localized: "Nada com este tamanho\(store.onlyOld ? " sem uso há 6 meses" : "")."))
            }
            ForEach(store.shown.prefix(30)) { f in row(f) }
            if let m = store.message { note(m, color: .text2) }
        }
        .cardStyle()
    }

    @ViewBuilder private func row(_ f: BigFile) -> some View {
        VStack(alignment: .leading, spacing: DS.xs) {
            HStack(spacing: DS.sm) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: f.path)).resizable().frame(width: 20, height: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L(f.name)).font(DS.body).lineLimit(1).truncationMode(.middle)
                    Text(L(detail(f))).font(DS.meta).foregroundStyle(Color.text3).lineLimit(1).truncationMode(.head)
                }
                Spacer(minLength: DS.sm)
                Text(L(Fmt.diskShort(f.size))).font(DS.body.monospacedDigit()).fixedSize()
                textLink("Lixo") { store.confirming = f.id }
                    .help("Mover para o Lixo")
            }
            if store.confirming == f.id {
                ConfirmBar(text: String(localized: "Mover \(f.name) (\(Fmt.disk(f.size))) para o Lixo? Podes recuperá-lo enquanto não o esvaziares."),
                           confirm: "Mover para o Lixo", cancel: { store.confirming = nil }, action: { store.trash(f) })
            }
        }
        .padding(.vertical, 2)
        .contextMenu {
            Button("Mostrar no Finder") { store.reveal(f) }
            Button("Abrir") { NSWorkspace.shared.open(URL(fileURLWithPath: f.path)) }
        }
    }

    private func detail(_ f: BigFile) -> String {
        let folder = ((f.path as NSString).deletingLastPathComponent as NSString).abbreviatingWithTildeInPath
        return String(localized: "\(folder) · usado \(LargeFilesRules.age(f.lastTouched, now: store.now))")
    }
}
