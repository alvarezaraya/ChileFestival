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
            case .loaded(let feed):
                FestivalsScreen(feed: feed)
            case .failed(let message):
                ErrorView(message: message) { model.load() }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black)
        .preferredColorScheme(.dark)
    }
}

// MARK: - ViewModel
//
// Carga 100 % local: el festivals.json del bundle es la única fuente en
// runtime (los datos se actualizan con cada versión de la app). `failed` solo
// puede darse si el JSON incluido viene malformado — se notaría en desarrollo.

@MainActor
final class FeedViewModel: ObservableObject {
    enum State {
        case loaded(FestivalFeed)
        case failed(String)
    }

    @Published private(set) var state: State

    init() { state = Self.loadState() }

    func load() { state = Self.loadState() }

    private static func loadState() -> State {
        do    { return .loaded(try FestivalLoader.loadBundled()) }
        catch { return .failed(error.localizedDescription) }
    }
}

// MARK: - Vista de error

struct ErrorView: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
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
