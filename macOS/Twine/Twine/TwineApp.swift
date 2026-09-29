//
//  TwineApp.swift
//  Twine
//
//  Created by Aravind Nidadavolu on 9/26/26.
//

import SwiftUI

@main
struct TwineApp: App {
    @State private var bridgeClient = BridgeClient()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(bridgeClient)
                .task {
                    bridgeClient.start()
                }
        }
    }
}
