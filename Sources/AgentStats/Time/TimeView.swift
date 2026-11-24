import SwiftUI

struct TimeView: View {
    @ObservedObject var timer: TimerStore
    @ObservedObject var clock: WorldClockStore
    @StateObject private var search = Box("")
    @StateObject private var minutes = Box<Double>(10)

    var body: some View {
        VStack(alignment: .leading, spacing: DS.md) {
            timerCard
            clockCard
        }
    }

    // MARK: Temporizador

    private var timerCard: some View {
        VStack(alignment: .leading, spacing: DS.sm) {
            if let plan = timer.plan {
                HStack(alignment: .firstTextBaseline) {
                    Text(L(plan.title)).font(DS.body.weight(.medium))
                    if plan.phase != .timer {
                        Text("· \(plan.completedFocus) de \(TimerPlan.focusPerLongBreak)").font(DS.meta).foregroundStyle(Color.text3)
                    }
                    Spacer()
                }
                Text(L(TimerPlan.clock(timer.left))).font(.system(size: 40, weight: .light).monospacedDigit())
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel("Faltam \(TimerPlan.clock(timer.left))")
                Bar(value: 1 - timer.left / max(plan.duration, 1), color: plan.phase == .focus || plan.phase == .timer ? .accentColor : Palette.working, height: 4)
                HStack(spacing: DS.sm) {
                    Button(timer.pausedLeft == nil ? "Pausa" : "Continuar") { timer.pauseOrResume() }
                    Button("Parar", role: .destructive) { timer.stop() }
                    Spacer()
                }
                .controlSize(.small)
            } else {
                Text("Temporizador").font(DS.body.weight(.medium))
                HStack(spacing: DS.xs) {
                    ForEach([5.0, 10, 15, 25, 45, 60], id: \.self) { m in
                        Button("\(Int(m))") { timer.startTimer(minutes: m) }
                            .controlSize(.small).help("\(Int(m)) minutos")
                    }
                }
                HStack(spacing: DS.sm) {
                    Stepper(String(localized: "\(Int(minutes.value)) min"), value: $minutes.value, in: 1...240, step: 1).font(DS.body)
                    Spacer()
                    Button("Começar") { timer.startTimer(minutes: minutes.value) }.controlSize(.small)
                }
                Divider().opacity(0.5)
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Pomodoro").font(DS.body)
                        Text("25 min de foco, 5 de pausa; a cada 4, 15 min").font(DS.meta).foregroundStyle(Color.text3)
                    }
                    Spacer()
                    Button("Começar") { timer.startPomodoro() }.controlSize(.small)
                }
                note("Enquanto corre, o tempo aparece na barra de menus. No fim, toca e avisa.")
            }
        }
        .cardStyle()
    }

    // MARK: Relógio mundial

    private var clockCard: some View {
        VStack(alignment: .leading, spacing: DS.sm) {
            Text("Relógio mundial").font(DS.body.weight(.medium))
            TimelineView(.everyMinute) { context in
                VStack(spacing: DS.xs) {
                    ForEach(clock.zones, id: \.identifier) { z in zoneRow(z, at: context.date) }
                }
            }
            if clock.zones.isEmpty { note("Junta as cidades das pessoas com quem trabalhas.") }
            TextField("Juntar cidade (ex.: Tóquio, New York)", text: $search.value)
                .textFieldStyle(.roundedBorder).font(DS.body)
            ForEach(WorldClock.search(search.value), id: \.identifier) { z in
                Button {
                    clock.add(z)
                    search.value = ""
                } label: {
                    HStack {
                        Text(L(WorldClock.city(z))).font(DS.body)
                        Text(L(z.identifier)).font(DS.meta).foregroundStyle(Color.text3)
                        Spacer()
                        Image(systemName: "plus").font(DS.meta)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .cardStyle()
    }

    private func zoneRow(_ z: TimeZone, at date: Date) -> some View {
        let note: String = [WorldClock.offset(z, from: .current, at: date), WorldClock.dayNote(z, local: .current, at: date)]
            .compactMap { $0 }.map { L($0) }.joined(separator: " · ")
        return HStack(spacing: DS.sm) {
            VStack(alignment: .leading, spacing: 2) {
                Text(L(WorldClock.city(z))).font(DS.body)
                Text(L(note)).font(DS.meta).foregroundStyle(Color.text3)
            }
            Spacer()
            Text(L(WorldClock.time(z, at: date))).font(.system(size: 20, weight: .regular).monospacedDigit())
        }
        .contextMenu {
            Button("Subir") { clock.move(z, by: -1) }
            Button("Descer") { clock.move(z, by: 1) }
            Divider()
            Button("Remover", role: .destructive) { clock.remove(z) }
        }
    }
}
