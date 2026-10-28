//
//  GameSetup.swift
//  WhiskyKit
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

import Foundation
import os.log

private let logger = Logger(subsystem: Bundle.whiskyBundleIdentifier, category: "GameSetup")

/// A game whose recommended configuration needs a bottle of its own.
public struct GameSetupPlan: Sendable, Equatable {
    public let entry: GameDBEntry
    public let variant: GameConfigVariant

    public init(entry: GameDBEntry, variant: GameConfigVariant) {
        self.entry = entry
        self.variant = variant
    }

    /// The runtime the game's bottle runs on.
    public var runtime: WineRuntime {
        variant.requiredRuntime.map { GameRuntimeInstaller.runtime(for: $0) } ?? .standard
    }
}

/// Where a ``GameSetupPlan`` stands. Each step needs the ones before it.
public struct GameSetupStatus: Sendable, Equatable {
    /// The required runtime is installed with its fixups, or none is required.
    public var runtimeReady: Bool
    /// Apple's GPTK payload is imported and deployed into that runtime, or the
    /// variant does not need it.
    public var gptkReady: Bool
    /// The bottle made for the game exists and has its configuration.
    public var bottleReady: Bool
    /// Steam is installed in that bottle.
    public var steamInstalled: Bool
    /// The game is installed in that bottle's Steam library.
    public var gameInstalled: Bool
    /// Someone has logged in to Steam in that bottle.
    public var steamLoggedIn: Bool

    public var isComplete: Bool {
        runtimeReady && gptkReady && bottleReady && steamInstalled && gameInstalled && steamLoggedIn
    }

    public init(
        runtimeReady: Bool, gptkReady: Bool, bottleReady: Bool,
        steamInstalled: Bool, gameInstalled: Bool, steamLoggedIn: Bool
    ) {
        self.runtimeReady = runtimeReady
        self.gptkReady = gptkReady
        self.bottleReady = bottleReady
        self.steamInstalled = steamInstalled
        self.gameInstalled = gameInstalled
        self.steamLoggedIn = steamLoggedIn
    }
}

/// Gives a game whose configuration needs more than settings (a specific
/// runtime, Apple's GPTK payload, registry values) a bottle of its own.
///
/// The game's bottle runs on its runtime and carries its settings; every other
/// bottle, the general Steam bottle included, is left as it was. Writing into
/// the bottle rather than applying a variant per launch (``LaunchResolver``)
/// matters for Steam games: one started from inside the Steam client never goes
/// through Whisky's launch path.
public enum GameSetup {
    /// The setup the game with `steamAppId` needs, or `nil` when its recommended
    /// variant (or the lack of one) needs none.
    public static func plan(steamAppId: Int, entries: [GameDBEntry]? = nil) -> GameSetupPlan? {
        let database = entries ?? GameDBLoader.loadDefaults()
        let metadata = ProgramMetadata(exeName: "", steamAppId: steamAppId)
        guard let match = GameMatcher.bestMatch(metadata: metadata, against: database),
              let variant = match.recommendedVariant,
              variant.needsSetup
        else { return nil }
        return GameSetupPlan(entry: match.entry, variant: variant)
    }

    /// The bottle made for the plan's game, if one exists.
    @MainActor
    public static func dedicatedBottle(for plan: GameSetupPlan, among bottles: [Bottle]) -> Bottle? {
        bottles.first { $0.settings.dedicatedGameID == plan.entry.id }
    }

    /// Checks each step against the runtimes, the GPTK store and the game's
    /// bottle. Reads files only; no Wine process is started.
    @MainActor
    public static func status(of plan: GameSetupPlan, dedicatedBottle bottle: Bottle?) -> GameSetupStatus {
        let runtimeReady = plan.variant.requiredRuntime.map { GameRuntimeInstaller.isSatisfied($0) } ?? true
        let gptkReady = plan.variant.requiresGPTK != true
            || (GPTKImporter.storedRecord() != nil && plan.runtime.isGPTKDeployed)
        guard let bottle, let appId = plan.entry.steamAppId else {
            return GameSetupStatus(
                runtimeReady: runtimeReady, gptkReady: gptkReady, bottleReady: false,
                steamInstalled: false, gameInstalled: false, steamLoggedIn: false
            )
        }
        return GameSetupStatus(
            runtimeReady: runtimeReady,
            gptkReady: gptkReady,
            bottleReady: isBottleConfigured(plan, bottle: bottle),
            steamInstalled: SteamLibrary.detectInstall(bottleURL: bottle.url) != nil,
            gameInstalled: SteamBottleSetup.hasGame(appId, bottleURL: bottle.url),
            steamLoggedIn: SteamBottleSetup.hasLogin(bottleURL: bottle.url)
        )
    }

    /// Marks `bottle` as the plan's game's, puts it on the game's runtime, and
    /// writes the variant's settings, registry values and per-executable DLL
    /// overrides into it.
    ///
    /// Settings go through ``GameConfigApplicator`` so they can be reverted from
    /// the game's configuration screen. DLL overrides are written per executable
    /// so that one such as disabling Steam's overlay renderer stays with the game.
    @MainActor
    public static func configureBottle(_ plan: GameSetupPlan, bottle: Bottle) async throws {
        bottle.settings.dedicatedGameID = plan.entry.id
        bottle.settings.runtimeVersion = plan.variant.requiredRuntime?.version

        let settingsOnly = GameConfigVariant(
            id: plan.variant.id,
            label: plan.variant.label,
            settings: plan.variant.settings,
            winetricksVerbs: plan.variant.winetricksVerbs
        )
        _ = try GameConfigApplicator.apply(entry: plan.entry, variant: settingsOnly, to: bottle)

        for value in registryWrites(for: plan) {
            try await Wine.addRegistryKey(
                bottle: bottle,
                key: value.key,
                name: value.name,
                data: value.data,
                type: RegistryType(rawValue: value.type) ?? .string
            )
        }
        logger.info("Configured \(bottle.settings.name, privacy: .public) for \(plan.entry.title, privacy: .public)")
    }

    /// The variant's registry values plus one `AppDefaults` value per DLL
    /// override and game executable.
    static func registryWrites(for plan: GameSetupPlan) -> [GameRegistryValue] {
        var writes = plan.variant.registryValues ?? []
        for exeName in plan.entry.exeNames ?? [] {
            for override in plan.variant.dllOverrides ?? [] {
                writes.append(GameRegistryValue(
                    key: #"HKCU\Software\Wine\AppDefaults\"# + exeName + #"\DllOverrides"#,
                    name: override.dllName,
                    type: RegistryType.string.rawValue,
                    data: override.mode.rawValue
                ))
            }
        }
        return writes
    }

    @MainActor
    static func isBottleConfigured(_ plan: GameSetupPlan, bottle: Bottle) -> Bool {
        bottle.settings.dedicatedGameID == plan.entry.id
            && bottle.settings.runtimeVersion == plan.variant.requiredRuntime?.version
            && settingsMatch(plan.variant.settings, bottle.settings)
            && registryWrites(for: plan).allSatisfy { registryHolds($0, bottleURL: bottle.url) }
    }

    static func settingsMatch(_ wanted: GameConfigVariantSettings, _ settings: BottleSettings) -> Bool {
        let checks: [Bool?] = [
            wanted.graphicsBackend.map { $0 == settings.graphicsBackend },
            wanted.enhancedSync.map { $0 == settings.enhancedSync },
            wanted.dxvkAsync.map { $0 == settings.dxvkAsync },
            wanted.shaderCacheEnabled.map { $0 == settings.shaderCacheEnabled },
            wanted.avxEnabled.map { $0 == settings.avxEnabled },
            wanted.metal4Enabled.map { $0 == settings.metal4Enabled },
            wanted.metalFX.map { $0 == settings.metalFX }
        ]
        return checks.allSatisfy { $0 ?? true }
    }

    /// Whether the prefix's `.reg` file holds `value`. Wine writes those files
    /// lazily, so a value set seconds ago can still read as missing.
    static func registryHolds(_ value: GameRegistryValue, bottleURL: URL) -> Bool {
        guard let stored = WineRegistryFile.readValue(bottleURL: bottleURL, key: value.key, valueName: value.name)
        else { return false }
        if value.type == RegistryType.dword.rawValue {
            let hex = stored.lowercased().replacingOccurrences(of: "dword:", with: "")
            return Int(hex, radix: 16) == Int(value.data)
        }
        return stored == value.data
    }
}
