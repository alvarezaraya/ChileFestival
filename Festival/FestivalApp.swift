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
//
// Primer arranque → onboarding (elegir hasta 3 festivales a seguir; desde el
// cuarto, paywall). Después → carrusel filtrado a lo seguido, con un botón para
// reabrir la misma pantalla de selección como sheet.

struct RootView: View {
    @StateObject private var model = FeedViewModel()
    @StateObject private var followStore = FollowStore()
    @StateObject private var entitlements = EntitlementStore()
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @State private var showFollowEditor = false

    var body: some View {
        Group {
            switch model.state {
            case .loaded(let feed):
                if hasCompletedOnboarding {
                    FestivalsScreen(
                        feed: feed.filtered(bySeriesKeys: followStore.followedKeys),
                        onEditFollows: { showFollowEditor = true }
                    )
                    .sheet(isPresented: $showFollowEditor) {
                        FestivalSelectionScreen(
                            feed: feed, mode: .edit,
                            followStore: followStore, entitlements: entitlements,
                            onFinished: { showFollowEditor = false },
                            onCancel: { showFollowEditor = false }
                        )
                    }
                    // Reagenda los recordatorios al entrar al carrusel (incluye
                    // el primer arranque tras el onboarding, donde además se
                    // pide el permiso de notificaciones) y al editar follows.
                    .task(id: followStore.followedKeys) {
                        await FestivalReminders.sync(feed: feed,
                                                     followedKeys: followStore.followedKeys)
                    }
                } else {
                    FestivalSelectionScreen(
                        feed: feed, mode: .onboarding,
                        followStore: followStore, entitlements: entitlements,
                        onFinished: { hasCompletedOnboarding = true }
                    )
                }
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
