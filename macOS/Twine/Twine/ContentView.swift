//
//  ContentView.swift
//  Twine
//
//  Created by Aravind Nidadavolu on 9/26/26.
//

import SwiftUI

struct ContentView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Rust says: \(BridgeClient().add(2, 2))")
                .font(.headline)
            TerminalSurface()
                .frame(minWidth: 400, minHeight: 250)
        }
        .padding()
    }
}

#Preview {
    ContentView()
}
