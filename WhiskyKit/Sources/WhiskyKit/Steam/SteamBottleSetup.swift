//
//  SteamBottleSetup.swift
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

private let logger = Logger(subsystem: Bundle.whiskyBundleIdentifier, category: "SteamBottleSetup")

/// Errors from ``SteamBottleSetup``.
public enum SteamBottleSetupError: LocalizedError, Equatable {
    case gameNotFound
    case steamMissing
    case alreadyInstalled
    case installerTimedOut

    public var errorDescription: String? {
        switch self {
        case .gameNotFound: String(localized: "steamSetup.error.gameNotFound")
        case .steamMissing: String(localized: "steamSetup.error.steamMissing")
        case .alreadyInstalled: String(localized: "steamSetup.error.alreadyInstalled")
        case .installerTimedOut: String(localized: "steamSetup.error.installerTimedOut")
        }
    }
}

/// Puts Steam and a Steam game into a bottle made for that game (``GameSetup``).
public enum SteamBottleSetup {
    /// Valve's Windows installer.
    static let installerDownload = URL(string: "https://cdn.cloudflare.steamstatic.com/client/installer/SteamSetup.exe")

    /// Whether someone has logged in to the Steam client in this bottle.
    public static func hasLogin(bottleURL: URL) -> Bool {
        guard let root = SteamLibrary.detectInstall(bottleURL: bottleURL),
              let users = try? String(
                  contentsOf: root.appending(path: "config").appending(path: "loginusers.vdf"), encoding: .utf8
              )
        else { return false }
        return users.contains("\"AccountName\"")
    }

    /// Whether `appId` is installed in this bottle's Steam libraries.
    public static func hasGame(_ appId: Int, bottleURL: URL) -> Bool {
        SteamLibrary.enumerate(bottleURL: bottleURL).contains { $0.appId == appId }
    }

    /// Downloads Valve's installer and runs it silently in `bottle`, returning
    /// once `steam.exe` is in place. The client itself then updates on its
    /// first start.
    @MainActor
    public static func installSteam(in bottle: Bottle, timeout: Duration = .seconds(300)) async throws {
        guard SteamLibrary.detectInstall(bottleURL: bottle.url) == nil else { return }
        guard let source = installerDownload else { throw SteamBottleSetupError.steamMissing }

        let (download, _) = try await URLSession.shared.download(from: source)
        let installer = FileManager.default.temporaryDirectory.appending(path: "SteamSetup-\(UUID().uuidString).exe")
        try FileManager.default.moveItem(at: download, to: installer)
        defer { try? FileManager.default.removeItem(at: installer) }

        // The launch path returns once Wine has started the installer, not
        // when it finishes, so completion is steam.exe appearing.
        _ = try await Wine.runProgram(at: installer, args: ["/S"], bottle: bottle)
        let deadline = ContinuousClock.now + timeout
        while SteamLibrary.detectInstall(bottleURL: bottle.url) == nil {
            guard ContinuousClock.now < deadline else { throw SteamBottleSetupError.installerTimedOut }
            try await Task.sleep(for: .seconds(2))
        }
        logger.info("Installed Steam in \(bottle.settings.name, privacy: .public)")
    }

    /// Moves an installed game, files and manifest, from one bottle's Steam
    /// library to another's, so it does not have to be downloaded again.
    ///
    /// Both Steam clients must be closed: a running client rewrites the
    /// manifest it still believes it owns. The destination's client then picks
    /// the game up on its next start.
    public static func moveGame(_ appId: Int, from source: URL, to destination: URL) throws {
        guard let game = SteamLibrary.enumerate(bottleURL: source).first(where: { $0.appId == appId }) else {
            throw SteamBottleSetupError.gameNotFound
        }
        guard let destinationRoot = SteamLibrary.detectInstall(bottleURL: destination) else {
            throw SteamBottleSetupError.steamMissing
        }

        let fileManager = FileManager.default
        let sourceSteamapps = game.installURL.deletingLastPathComponent().deletingLastPathComponent()
        let destinationSteamapps = destinationRoot.appending(path: "steamapps")
        let destinationCommon = destinationSteamapps.appending(path: "common")
        let destinationGame = destinationCommon.appending(path: game.installURL.lastPathComponent)
        guard !fileManager.fileExists(atPath: destinationGame.path(percentEncoded: false)) else {
            throw SteamBottleSetupError.alreadyInstalled
        }

        try fileManager.createDirectory(at: destinationCommon, withIntermediateDirectories: true)
        let manifestName = "appmanifest_\(appId).acf"
        try fileManager.moveItem(at: game.installURL, to: destinationGame)
        try fileManager.moveItem(
            at: sourceSteamapps.appending(path: manifestName),
            to: destinationSteamapps.appending(path: manifestName)
        )
        logger.info("Moved app \(appId) to \(destination.lastPathComponent, privacy: .public)")
    }
}
