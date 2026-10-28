//
//  GameRuntimeInstaller.swift
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
import SemanticVersion

private let logger = Logger(subsystem: Bundle.whiskyBundleIdentifier, category: "GameRuntimeInstaller")

/// Errors from ``GameRuntimeInstaller``.
public enum GameRuntimeError: LocalizedError, Equatable {
    case checksumMismatch
    case unexpectedLayout

    public var errorDescription: String? {
        switch self {
        case .checksumMismatch: String(localized: "gameRuntime.error.checksum")
        case .unexpectedLayout: String(localized: "gameRuntime.error.layout")
        }
    }
}

/// Installs the runtime a game configuration needs (``GameRuntimeRequirement``)
/// beside the standard one, in `Runtimes/<version>` (``WineRuntime``).
///
/// Only bottles set to that version run on it, so installing it changes nothing
/// for any other bottle, and the standard runtime keeps its own updates.
public enum GameRuntimeInstaller {
    /// Where `requirement`'s runtime lives once installed.
    public static func runtime(
        for requirement: GameRuntimeRequirement,
        in runtimesFolder: URL = WineRuntime.runtimesFolder
    ) -> WineRuntime {
        .versioned(requirement.version, in: runtimesFolder)
    }

    /// Whether the required version is installed with every fixup applied.
    public static func isSatisfied(
        _ requirement: GameRuntimeRequirement,
        in runtimesFolder: URL = WineRuntime.runtimesFolder
    ) -> Bool {
        let runtime = runtime(for: requirement, in: runtimesFolder)
        guard runtime.isInstalled,
              let installed = runtime.info?.version,
              let required = SemanticVersion(requirement.version),
              installed == required
        else { return false }
        return RuntimeFixups.pending(requirement.fixups, inRuntimeAt: runtime.libraryFolder).isEmpty
    }

    /// Downloads, verifies, fixes and installs the required runtime.
    ///
    /// The archive is extracted and fixed in a staging folder beside the
    /// destination, so a failure leaves nothing half-installed and the final
    /// step is a rename. Deploying the GPTK payload into it is left to the
    /// caller (``WineRuntime/deployGPTKIfCapable()``).
    @discardableResult
    public static func install(
        _ requirement: GameRuntimeRequirement,
        gameTitle: String,
        in runtimesFolder: URL = WineRuntime.runtimesFolder
    ) async throws -> WineRuntime {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: runtimesFolder, withIntermediateDirectories: true)
        let staging = try fileManager.url(
            for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: runtimesFolder, create: true
        )
        defer { try? fileManager.removeItem(at: staging) }

        logger.info("Downloading runtime \(requirement.version, privacy: .public) for \(gameTitle, privacy: .public)")
        let (download, _) = try await URLSession.shared.download(from: requirement.downloadURL)
        let archive = staging.appending(path: "Libraries.tar.gz")
        try fileManager.moveItem(at: download, to: archive)
        guard WhiskyWineInstaller.sha256(ofFileAt: archive)?.lowercased() == requirement.sha256.lowercased() else {
            throw GameRuntimeError.checksumMismatch
        }

        try Tar.untar(tarBall: archive, toURL: staging)
        let fresh = staging.appending(path: "Libraries")
        guard WhiskyWineInstaller.isRuntimePresent(inLibraryFolder: fresh) else {
            throw GameRuntimeError.unexpectedLayout
        }
        try RuntimeFixups.apply(requirement.fixups, toRuntimeAt: fresh)

        let runtime = runtime(for: requirement, in: runtimesFolder)
        if fileManager.fileExists(atPath: runtime.libraryFolder.path(percentEncoded: false)) {
            try fileManager.removeItem(at: runtime.libraryFolder)
        }
        try fileManager.moveItem(at: fresh, to: runtime.libraryFolder)
        logger.info("Installed runtime \(requirement.version, privacy: .public)")
        return runtime
    }
}
