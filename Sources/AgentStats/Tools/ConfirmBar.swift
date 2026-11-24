import SwiftUI
import AppKit

/// Confirmação dentro do painel (um alerta fechava-o): diz o que vai acontecer e "Cancelar" vem primeiro.
struct ConfirmBar: View {
    let text: String
    let confirm: String
    let cancel: () -> Void
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DS.sm) {
            Text(L(text)).font(DS.meta).foregroundStyle(Color.primary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: DS.sm) {
                Spacer(minLength: 0)
                Button("Cancelar", action: cancel)
                Button(L(confirm), role: .destructive, action: action)
            }
            .controlSize(.small)
        }
        .padding(DS.sm)
        .background(RoundedRectangle(cornerRadius: DS.rSmall, style: .continuous).fill(Palette.attention.opacity(0.08)))
    }
}
