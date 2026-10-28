//
//  GameSetupTests.swift
//  WhiskyKitTests
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
import SemanticVersion
import Testing
@testable import WhiskyKit

@Suite("Game setup")
struct GameSetupTests {
    static let residentEvil2 = 883_710

    @Test("Resident Evil 2 needs the pinned runtime, GPTK and registry values")
    func residentEvil2Plan() throws {
        let plan = try #require(GameSetup.plan(steamAppId: Self.residentEvil2))
        #expect(plan.entry.id == "resident-evil-2")
        #expect(plan.variant.requiresGPTK == true)
        #expect(plan.variant.settings.metal4Enabled == false)
        #expect(plan.variant.settings.metalFX == false)

        let runtime = try #require(plan.variant.requiredRuntime)
        #expect(runtime.version == "4.0.0")
        #expect(runtime.fixups == [.systemLibiconv])
        #expect(runtime.sha256.count == 64)
    }

    @Test("Setup writes the registry values and keeps DLL overrides per executable")
    func registryWrites() throws {
        let plan = try #require(GameSetup.plan(steamAppId: Self.residentEvil2))
        let writes = GameSetup.registryWrites(for: plan)
        #expect(writes.contains(GameRegistryValue(
            key: #"HKCU\Software\Wine\MediaFoundation"#,
            name: "DisableGstByteStreamHandler",
            type: "REG_DWORD",
            data: "1"
        )))
        #expect(writes.contains(GameRegistryValue(
            key: #"HKCU\Software\Wine\AppDefaults\re2.exe\DllOverrides"#,
            name: "gameoverlayrenderer64",
            type: "REG_SZ",
            data: ""
        )))
    }

    @Test("A game whose variant needs only settings has no setup")
    func noPlanWithoutRequirements() {
        // Monster Hunter Wilds: settings and winetricks only.
        #expect(GameSetup.plan(steamAppId: 2_246_340) == nil)
        #expect(GameSetup.plan(steamAppId: 1) == nil)
    }

    @Test("An unknown runtime fixup is dropped instead of failing the decode")
    func unknownFixupIsDropped() throws {
        let json = Data("""
        {"version": "4.0.0", "downloadURL": "https://example.com/Libraries.tar.gz",
         "sha256": "00", "fixups": ["systemLibiconv", "somethingNewer"]}
        """.utf8)
        let requirement = try JSONDecoder().decode(GameRuntimeRequirement.self, from: json)
        #expect(requirement.fixups == [.systemLibiconv])
    }

    @Test("Registry values are read back from the prefix's .reg files")
    func registryValuesReadBack() throws {
        let bottle = FileManager.default.temporaryDirectory.appending(path: "GameSetup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: bottle, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: bottle) }
        try """
        WINE REGISTRY Version 2

        [Software\\\\Wine\\\\AppDefaults\\\\re2.exe\\\\DllOverrides] 1793200217
        "gameoverlayrenderer64"=""

        [Software\\\\Wine\\\\MediaFoundation] 1793200217
        "DisableGstByteStreamHandler"=dword:00000001

        """.write(to: bottle.appending(path: "user.reg"), atomically: true, encoding: .utf8)

        let plan = try #require(GameSetup.plan(steamAppId: Self.residentEvil2))
        for value in GameSetup.registryWrites(for: plan) {
            #expect(GameSetup.registryHolds(value, bottleURL: bottle), "\(value.key) \(value.name)")
        }
        let disabled = GameRegistryValue(
            key: #"HKCU\Software\Wine\MediaFoundation"#,
            name: "DisableGstByteStreamHandler",
            type: "REG_DWORD",
            data: "0"
        )
        #expect(!GameSetup.registryHolds(disabled, bottleURL: bottle))
    }

    @Test("Bottle settings are compared only where the variant sets them")
    func settingsMatch() {
        var settings = BottleSettings()
        settings.enhancedSync = .msync
        settings.metal4Enabled = false
        let wanted = GameConfigVariantSettings(enhancedSync: .msync, metal4Enabled: false)
        #expect(GameSetup.settingsMatch(wanted, settings))

        settings.metal4Enabled = true
        #expect(!GameSetup.settingsMatch(wanted, settings))
    }

    @Test("The launch plan carries the variant's Metal 4 setting")
    func launchPlanCarriesMetal4() {
        let merged = LaunchResolver.merge(
            variant: GameConfigVariantSettings(metal4Enabled: false), dllOverrides: nil, under: nil
        )
        #expect(merged.metal4Enabled == false)
    }
}

@Suite("Game runtimes and bottles")
struct GameRuntimeInstallerTests {
    static let requirement = GameRuntimeRequirement(
        version: "4.0.0",
        downloadURL: URL(filePath: "/dev/null/Libraries.tar.gz"),
        sha256: String(repeating: "0", count: 64),
        fixups: [.systemLibiconv]
    )

    static func temporaryFolder(_ name: String) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// A `Libraries`-shaped runtime of `version` with a wine64 stub in it.
    static func makeRuntime(_ version: SemanticVersion, at libraries: URL) throws {
        let bin = libraries.appending(path: "Wine").appending(path: "bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try Data().write(to: bin.appending(path: "wine64"))
        try PropertyListEncoder().encode(WhiskyWineVersion(version: version))
            .write(to: libraries.appending(path: "WhiskyWineVersion.plist"))
    }

    @Test("Only the required version, installed, satisfies the requirement")
    func satisfiedByVersion() throws {
        let runtimes = try Self.temporaryFolder("Runtimes")
        defer { try? FileManager.default.removeItem(at: runtimes) }
        let requirement = Self.requirement

        #expect(!GameRuntimeInstaller.isSatisfied(requirement, in: runtimes))
        try Self.makeRuntime(SemanticVersion(3, 1, 1), at: runtimes.appending(path: "4.0.0"))
        #expect(!GameRuntimeInstaller.isSatisfied(requirement, in: runtimes))
        try Self.makeRuntime(SemanticVersion(4, 0, 0), at: runtimes.appending(path: "4.0.0"))
        #expect(GameRuntimeInstaller.isSatisfied(requirement, in: runtimes))
    }

    @Test("A bottle's runtime falls back to the standard one when it is missing")
    func runtimeFallsBack() throws {
        let runtimes = try Self.temporaryFolder("Runtimes")
        defer { try? FileManager.default.removeItem(at: runtimes) }

        #expect(WineRuntime.forVersion(nil, in: runtimes) == .standard)
        #expect(WineRuntime.forVersion("4.0.0", in: runtimes) == .standard)
        try Self.makeRuntime(SemanticVersion(4, 0, 0), at: runtimes.appending(path: "4.0.0"))
        let runtime = WineRuntime.forVersion("4.0.0", in: runtimes)
        #expect(runtime.libraryFolder == runtimes.appending(path: "4.0.0"))
        #expect(runtime.wineBinary.lastPathComponent == "wine64")
        #expect(WineRuntime.gameRuntimes(in: runtimes).map(\.libraryFolder.lastPathComponent) == ["4.0.0"])
    }

    /// A bottle with Steam installed and, optionally, one game in its library.
    static func makeSteamBottle(game: (appId: Int, folder: String)?) throws -> URL {
        let bottle = try temporaryFolder("Bottle")
        let steam = bottle.appending(path: "drive_c/Program Files (x86)/Steam")
        let steamapps = steam.appending(path: "steamapps")
        try FileManager.default.createDirectory(at: steamapps, withIntermediateDirectories: true)
        try Data().write(to: steam.appending(path: "steam.exe"))
        if let game {
            let installDir = steamapps.appending(path: "common").appending(path: game.folder)
            try FileManager.default.createDirectory(at: installDir, withIntermediateDirectories: true)
            try Data("pak".utf8).write(to: installDir.appending(path: "re_chunk_000.pak"))
            try """
            "AppState"
            {
            \t"appid"\t\t"\(game.appId)"
            \t"name"\t\t"Resident Evil 2"
            \t"installdir"\t\t"\(game.folder)"
            \t"StateFlags"\t\t"4"
            }
            """.write(to: steamapps.appending(path: "appmanifest_\(game.appId).acf"), atomically: true, encoding: .utf8)
        }
        return bottle
    }

    @Test("A game moves between bottles with its manifest, without a download")
    func movesGameBetweenBottles() throws {
        let appId = 883_710
        let source = try Self.makeSteamBottle(game: (appId, "RESIDENT EVIL 2  BIOHAZARD RE2"))
        let destination = try Self.makeSteamBottle(game: nil)
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: destination)
        }

        #expect(SteamBottleSetup.hasGame(appId, bottleURL: source))
        try SteamBottleSetup.moveGame(appId, from: source, to: destination)
        #expect(SteamBottleSetup.hasGame(appId, bottleURL: destination))
        #expect(!SteamBottleSetup.hasGame(appId, bottleURL: source))
        #expect(throws: SteamBottleSetupError.gameNotFound) {
            try SteamBottleSetup.moveGame(appId, from: source, to: destination)
        }
    }

    @Test("Steam counts as logged in once loginusers.vdf names an account")
    func detectsSteamLogin() throws {
        let bottle = try Self.makeSteamBottle(game: nil)
        defer { try? FileManager.default.removeItem(at: bottle) }
        #expect(!SteamBottleSetup.hasLogin(bottleURL: bottle))

        let config = bottle.appending(path: "drive_c/Program Files (x86)/Steam/config")
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        try "\"users\"\n{\n\t\"7656\"\n\t{\n\t\t\"AccountName\"\t\t\"someone\"\n\t}\n}\n"
            .write(to: config.appending(path: "loginusers.vdf"), atomically: true, encoding: .utf8)
        #expect(SteamBottleSetup.hasLogin(bottleURL: bottle))
    }
}
