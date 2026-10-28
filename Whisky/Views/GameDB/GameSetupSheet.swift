//
//  GameSetupSheet.swift
//  Whisky
//
//  This file is part of Whisky.
//
//  Whisky is free software: you can redistribute it and/or modify it under the terms
//  of the GNU General Public License as published by the Free Software Foundation,
//  either version 3 of the License, or (at your option) any later version.
//
//  Whisky is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY;
//  without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
//  See the GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License along with Whisky.
//  If not, see https://www.gnu.org/licenses/.
//

import SwiftUI
import UniformTypeIdentifiers
import WhiskyKit

/// Walks the user through giving a game its own bottle (``GameSetupPlan``).
///
/// Each step needs the ones above it. What Whisky can do on its own runs from a
/// button; what it cannot, downloading Apple's GPTK and logging in to Steam, is
/// explained with the control that gets the user there.
struct GameSetupSheet: View {
    let plan: GameSetupPlan
    /// The bottle the game is installed in now, if any; it is moved from there.
    let sourceBottle: Bottle?
    /// Starts the game in its own bottle once setup is complete.
    let play: (Bottle) -> Void

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var bottleVM = BottleVM.shared
    @State private var status: GameSetupStatus?
    @State private var working: Step?
    @State private var showImporter = false
    @State private var errorMessage: String?

    private enum Step {
        case runtime, gptk, bottle, steam, game, login
    }

    private static let gptkDownloads = URL(
        string: "https://developer.apple.com/download/all/?q=Game%20Porting%20Toolkit"
    )

    private var gameBottle: Bottle? {
        GameSetup.dedicatedBottle(for: plan, among: bottleVM.bottles)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("gameSetup.title \(plan.entry.title)")
                    .font(.title2.bold())
                Text("gameSetup.subtitle \(plan.entry.title)")
                    .foregroundStyle(.secondary)
            }

            ScrollView {
                VStack(spacing: 8) {
                    steps
                }
            }
            .frame(maxHeight: 460)

            HStack {
                Spacer()
                Button(status?.isComplete == true ? "gameSetup.done" : "gameSetup.later") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button("gameSetup.play") {
                    guard let gameBottle else { return }
                    dismiss()
                    play(gameBottle)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(status?.isComplete != true)
            }
        }
        .padding(20)
        .frame(width: 560)
        .task { await refresh() }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.diskImage, .folder]) { result in
            guard case let .success(url) = result else { return }
            perform(.gptk) {
                try await Task.detached(priority: .userInitiated) {
                    try GPTKDiskImage.importAndDeploy(from: url)
                }.value
            }
        }
        .alert(
            "gameSetup.failed",
            isPresented: .init(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button("button.ok", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: - Steps

    @ViewBuilder
    private var steps: some View {
        let status = status
        if let requirement = plan.variant.requiredRuntime {
            SetupStepRow(
                title: Text("gameSetup.runtime.title \(requirement.version)"),
                detail: Text("gameSetup.runtime.detail \(plan.entry.title)"),
                isDone: status?.runtimeReady == true,
                isWorking: working == .runtime
            ) {
                Button("gameSetup.runtime.install") {
                    perform(.runtime) {
                        let runtime = try await GameRuntimeInstaller.install(requirement, gameTitle: plan.entry.title)
                        await Task.detached { runtime.deployGPTKIfCapable() }.value
                    }
                }
                .disabled(working != nil)
            }
        }

        if plan.variant.requiresGPTK == true {
            SetupStepRow(
                title: Text("gameSetup.gptk.title"),
                detail: Text("gameSetup.gptk.detail"),
                isDone: status?.gptkReady == true,
                isWorking: working == .gptk
            ) {
                if let url = Self.gptkDownloads {
                    Link("gameSetup.gptk.download", destination: url)
                }
                Button("gameSetup.gptk.import") {
                    showImporter = true
                }
                .disabled(working != nil || status?.runtimeReady != true)
            }
        }

        SetupStepRow(
            title: Text("gameSetup.bottle.title \(plan.entry.title)"),
            detail: Text("gameSetup.bottle.detail"),
            isDone: status?.bottleReady == true,
            isWorking: working == .bottle
        ) {
            Button(gameBottle == nil ? "gameSetup.bottle.create" : "gameSetup.bottle.apply") {
                perform(.bottle) { try await configureGameBottle() }
            }
            .disabled(working != nil || status?.runtimeReady != true || status?.gptkReady != true)
        }

        SetupStepRow(
            title: Text("gameSetup.steam.title"),
            detail: Text("gameSetup.steam.detail"),
            isDone: status?.steamInstalled == true,
            isWorking: working == .steam
        ) {
            Button("gameSetup.steam.install") {
                guard let gameBottle else { return }
                perform(.steam) { try await SteamBottleSetup.installSteam(in: gameBottle) }
            }
            .disabled(working != nil || status?.bottleReady != true)
        }

        gameStep(status)

        SetupStepRow(
            title: Text("gameSetup.login.title"),
            detail: Text("gameSetup.login.detail"),
            isDone: status?.steamLoggedIn == true,
            isWorking: working == .login
        ) {
            Button("gameSetup.login.open") {
                openSteam()
            }
            .disabled(working != nil || status?.steamInstalled != true)
            Button("gameSetup.login.check") {
                Task { await refresh() }
            }
            .disabled(working != nil || status?.steamInstalled != true)
        }
    }

    private func gameStep(_ status: GameSetupStatus?) -> some View {
        let source = sourceBottle.flatMap { $0.url == gameBottle?.url ? nil : $0 }
        return SetupStepRow(
            title: Text("gameSetup.game.title \(plan.entry.title)"),
            detail: source.map { Text("gameSetup.game.move \($0.settings.name)") }
                ?? Text("gameSetup.game.install"),
            isDone: status?.gameInstalled == true,
            isWorking: working == .game
        ) {
            if let source {
                Button("gameSetup.game.moveButton") {
                    perform(.game) { try await moveGame(from: source) }
                }
                .disabled(working != nil || status?.steamInstalled != true)
            }
        }
    }

    // MARK: - Actions

    /// Runs one step, reporting a failure, then re-reads where setup stands.
    private func perform(_ step: Step, _ action: @escaping @MainActor () async throws -> Void) {
        working = step
        Task {
            do {
                try await action()
            } catch {
                errorMessage = error.localizedDescription
            }
            working = nil
            await refresh()
        }
    }

    private func refresh() async {
        // A runtime installed before the GPTK payload was imported still
        // needs it deployed.
        if plan.variant.requiresGPTK == true, GPTKImporter.storedRecord() != nil, !plan.runtime.isGPTKDeployed {
            let runtime = plan.runtime
            await Task.detached(priority: .userInitiated) { runtime.deployGPTKIfCapable() }.value
        }
        status = GameSetup.status(of: plan, dedicatedBottle: gameBottle)
    }

    private func configureGameBottle() async throws {
        let bottle: Bottle
        if let gameBottle {
            bottle = gameBottle
        } else {
            bottle = try await bottleVM.createGameBottle(
                name: plan.entry.title,
                runtimeVersion: plan.variant.requiredRuntime?.version,
                gameID: plan.entry.id
            )
        }
        try await GameSetup.configureBottle(plan, bottle: bottle)
    }

    /// Both Steam clients have to be closed: a running one rewrites the
    /// manifest it still thinks it owns.
    private func moveGame(from source: Bottle) async throws {
        guard let gameBottle, let appId = plan.entry.steamAppId else { return }
        for bottle in [source, gameBottle] {
            if await Wine.isWineserverRunning(for: bottle) {
                throw GameSetupSheetError.steamRunning(bottle.settings.name)
            }
        }
        let from = source.url
        let destination = gameBottle.url
        try await Task.detached(priority: .userInitiated) {
            try SteamBottleSetup.moveGame(appId, from: from, to: destination)
        }.value
    }

    private func openSteam() {
        guard let gameBottle, let root = SteamLibrary.detectInstall(bottleURL: gameBottle.url) else { return }
        Task {
            do {
                _ = try await Wine.runProgram(at: root.appending(path: "steam.exe"), bottle: gameBottle)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

private enum GameSetupSheetError: LocalizedError {
    case steamRunning(String)

    var errorDescription: String? {
        switch self {
        case let .steamRunning(bottle):
            String(format: String(localized: "gameSetup.game.steamRunning"), bottle)
        }
    }
}

/// One step of a setup checklist: what it is, and either a checkmark or the
/// controls that get it done.
private struct SetupStepRow<Actions: View>: View {
    let title: Text
    let detail: Text
    let isDone: Bool
    let isWorking: Bool
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: isDone ? "checkmark.circle.fill" : "circle.dashed")
                .font(.title3)
                .foregroundStyle(isDone ? Color.green : Color.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                title.font(.headline)
                detail
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !isDone {
                    HStack {
                        actions()
                        if isWorking {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .contain)
    }
}
