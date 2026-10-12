import AppKit
import SwiftUI
import Testing

@testable import Twine

@MainActor
struct RoleStyleTests {
    @Test func roleStylesAreStableAndMatchTheDesign() {
        #expect(RoleStyle(role: "implementer") == RoleStyle(role: "Implementer"))
        #expect(RoleStyle(role: "Implementer").color == .roleBlue)
        #expect(RoleStyle(role: "Reviewer").color == .roleOrange)
        #expect(RoleStyle(role: "Coordinator").color == .rolePurple)
        #expect(RoleStyle(role: "Worker").color == .roleGreen)
        #expect(RoleStyle(role: "Worker 2") == RoleStyle(role: "Worker"))
        // Custom roles keep a deterministic muted color, including numbered instances.
        #expect(RoleStyle(role: "Tester") == RoleStyle(role: "tester"))
        #expect(RoleStyle(role: "Tester 2") == RoleStyle(role: "Tester"))
        #expect([Color.roleBlue, .roleOrange, .rolePurple, .roleGreen].contains(RoleStyle(role: "Tester").color))
        let symbols = ["Implementer", "Reviewer", "Coordinator", "Worker", "Tester"].map { RoleStyle(role: $0).symbol }
        #expect(Set(symbols).count == symbols.count)
        #expect(!symbols.contains("arrow.triangle.branch"), "The footer's Git branch uses that symbol")
        for symbol in symbols {
            #expect(NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil, "\(symbol)")
        }
    }
}
