import Testing
@testable import AgentStats

@Suite struct TabLayoutTests {
    private let all: [Tab] = [.agents, .system, .processes, .audio, .clipboard, .capture, .tools]

    @Test func withNothingSavedItIsAsBefore() {
        #expect(TabLayout.order(nil) == all)
        #expect(TabLayout.visible(order: nil, hidden: nil) == all)
    }

    @Test func savedOrderWinsAndNewTabsGoToTheEnd() {
        #expect(TabLayout.order("tools,agents") == [.tools, .agents, .system, .processes, .audio, .clipboard, .capture])
        #expect(TabLayout.order("tools,lixo,tools,settings,agents").prefix(2) == [.tools, .agents])
    }

    @Test func hiddenTabsLeaveTheBarButNeverAll() {
        #expect(TabLayout.visible(order: nil, hidden: "audio,capture") == [.agents, .system, .processes, .clipboard, .tools])
        #expect(TabLayout.visible(order: "tools", hidden: TabLayout.encode(all)) == [.tools])
    }

    @Test func movingSwapsWithTheNeighbourAndStopsAtTheEnds() {
        #expect(TabLayout.order(TabLayout.moved(order: nil, .system, by: -1)).prefix(2) == [.system, .agents])
        #expect(TabLayout.order(TabLayout.moved(order: nil, .agents, by: -1)) == all)
        #expect(TabLayout.order(TabLayout.moved(order: nil, .tools, by: 1)) == all)
    }

    @Test func togglingNeverHidesTheLastVisible() {
        var hidden = ""
        for tab in all.dropLast() { hidden = TabLayout.toggled(hidden: hidden, tab, order: nil) }
        #expect(TabLayout.visible(order: nil, hidden: hidden) == [.tools])
        hidden = TabLayout.toggled(hidden: hidden, .tools, order: nil)
        #expect(TabLayout.visible(order: nil, hidden: hidden) == [.tools])
        hidden = TabLayout.toggled(hidden: hidden, .audio, order: nil)
        #expect(TabLayout.visible(order: nil, hidden: hidden) == [.audio, .tools])
    }

    @Test func whereThePanelOpens() {
        let shown: [Tab] = [.agents, .system, .tools]
        #expect(TabLayout.tabOnOpen(stored: .system, start: nil, visible: shown) == .system)
        #expect(TabLayout.tabOnOpen(stored: .system, start: "last", visible: shown) == .system)
        #expect(TabLayout.tabOnOpen(stored: .system, start: "tools", visible: shown) == .tools)
        #expect(TabLayout.tabOnOpen(stored: .settings, start: nil, visible: shown) == .settings)
        // escondido entretanto: vai para o primeiro que se vê
        #expect(TabLayout.tabOnOpen(stored: .audio, start: nil, visible: shown) == .agents)
        #expect(TabLayout.tabOnOpen(stored: .system, start: "audio", visible: shown) == .system)
    }

    @Test func shortcutsFollowTheBarOrder() {
        let shown: [Tab] = [.tools, .agents]
        #expect(TabLayout.shortcutTab(1, visible: shown) == .tools)
        #expect(TabLayout.shortcutTab(2, visible: shown) == .agents)
        #expect(TabLayout.shortcutTab(3, visible: shown) == nil)
        #expect(TabLayout.shortcutTab(0, visible: shown) == nil)
    }

    @MainActor @Test func shortcutKeysAreOptionCommandDigits() {
        #expect(TabHotKeys.combo(1).label == "⌥⌘1")
        #expect(TabHotKeys.combo(7).label == "⌥⌘7")
        #expect(Set(TabHotKeys.digits).count == TabHotKeys.digits.count)
    }
}
