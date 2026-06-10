//
//  FestivalApp.swift
//  Festival
//
//  Created by Felipe Álvarez on 07-06-26.
//

import SwiftUI
import Combine

@main
struct FestivalApp: App {
    var body: some Scene {
        WindowGroup { RootView() }
    }
}

// MARK: - Root: decide qué mostrar según el estado de carga

struct RootView: View {
    @StateObject private var model = FeedViewModel()

    var body: some View {
        Group {
            switch model.state {
            case .idle, .loading:
                ProgressView("Cargando festivales…")
                    .tint(.white)
            case .loaded(let feed):
                FestivalsScreen(feed: feed)
            case .failed(let message):
                ErrorView(message: message) {
                    Task { await model.load() }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black)
        .preferredColorScheme(.dark)
        .task { await model.load() }
    }
}

// MARK: - ViewModel

@MainActor
final class FeedViewModel: ObservableObject {
    enum State {
        case idle, loading
        case loaded(FestivalFeed)
        case failed(String)
    }

    @Published private(set) var state: State = .idle

    func load() async {
        state = .loading
        // 1. Bundle primero → arranque instantáneo, sin esperar red.
        let bundle = try? FestivalLoader.loadBundled()
        if let bundle { state = .loaded(bundle) }
        // 2. Refresco remoto silencioso (8 s de timeout). Se rellenan con el
        //    bundle los datos que el remoto traiga incompletos (fotos / IDs de
        //    Apple Music), para que un feed remoto más viejo no borre en runtime
        //    imágenes ya curadas localmente.
        do {
            let remote = try await FestivalLoader.loadRemote()
            state = .loaded(bundle.map(remote.backfilled(from:)) ?? remote)
        } catch {
            if bundle == nil {
                state = .failed(error.localizedDescription)
            }
        }
    }
}

// MARK: - Vista de error

struct ErrorView: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "wifi.exclamationmark")
                .font(.largeTitle)
            Text("No pude cargar los festivales")
                .font(.headline)
            Text(message)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.6))
                .multilineTextAlignment(.center)
            Button("Reintentar", action: retry)
                .buttonStyle(.borderedProminent)
        }
        .padding()
        .foregroundStyle(.white)
    }
}
