//
//  WineRuntime.swift
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

/// One installed Wine runtime: a `Libraries`-shaped folder holding Wine, DXVK,
/// DXMT and, once deployed, the GPTK payload.
///
/// The standard runtime is the one first-run setup installs and updates, in
/// `Libraries`. A game whose configuration was validated on a different one
/// (``GameRuntimeRequirement``) gets that runtime installed beside it, in
/// `Runtimes/<version>`, and only the bottles set to it
/// (``BottleSettings/runtimeVersion``) run on it.
public struct WineRuntime: Equatable, Sendable {
    /// The `Libraries`-shaped folder.
    public let libraryFolder: URL

    public init(libraryFolder: URL) {
        self.libraryFolder = libraryFolder
    }

    /// The runtime in `Libraries`.
    public static var standard: WineRuntime {
        WineRuntime(libraryFolder: WhiskyWineInstaller.libraryFolder)
    }

    /// Where non-standard runtimes are installed, one folder per version.
    public static var runtimesFolder: URL {
        WhiskyWineInstaller.applicationFolder.appending(path: "Runtimes")
    }

    /// The runtimes installed for games under `runtimesFolder`.
    public static func gameRuntimes(in runtimesFolder: URL = runtimesFolder) -> [WineRuntime] {
        let folders = (try? FileManager.default.contentsOfDirectory(
            at: runtimesFolder, includingPropertiesForKeys: nil, options: .skipsHiddenFiles
        )) ?? []
        return folders.map(WineRuntime.init(libraryFolder:)).filter(\.isInstalled)
    }

    /// The runtime of `version` under ``runtimesFolder``, installed or not.
    public static func versioned(_ version: String, in runtimesFolder: URL = runtimesFolder) -> WineRuntime {
        WineRuntime(libraryFolder: runtimesFolder.appending(path: version))
    }

    /// The runtime a bottle set to `version` runs on: that runtime when it is
    /// installed, otherwise the standard one, so a bottle whose runtime was
    /// removed still starts instead of failing to find Wine.
    public static func forVersion(_ version: String?, in runtimesFolder: URL = runtimesFolder) -> WineRuntime {
        guard let version else { return .standard }
        let runtime = versioned(version, in: runtimesFolder)
        return runtime.isInstalled ? runtime : .standard
    }

    public var binFolder: URL { libraryFolder.appending(path: "Wine").appending(path: "bin") }
    public var wineBinary: URL { binFolder.appending(path: "wine64") }
    public var wineserverBinary: URL { binFolder.appending(path: "wineserver") }
    public var dxvkFolder: URL { libraryFolder.appending(path: "DXVK") }
    public var dxmtFolder: URL { libraryFolder.appending(path: "DXMT") }

    /// The runtime's `WhiskyWineVersion.plist`.
    public var info: WhiskyWineVersion? {
        WhiskyWineInstaller.whiskyWineInfo(
            at: libraryFolder.appending(path: "WhiskyWineVersion").appendingPathExtension("plist")
        )
    }

    public var isInstalled: Bool {
        WhiskyWineInstaller.isRuntimePresent(inLibraryFolder: libraryFolder)
    }

    /// Whether this build of Wine can run Apple's GPTK payload.
    public var isGPTKCapable: Bool {
        info?.gptkCapable == true
    }

    /// Whether the GPTK payload is deployed into this runtime.
    public var isGPTKDeployed: Bool {
        GPTKImporter.isDeployed(inLibraryFolder: libraryFolder)
    }

    public var isD3DMetalInstalled: Bool {
        WhiskyWineInstaller.isD3DMetalPresent(inLibraryFolder: libraryFolder)
    }

    public var isDXMTNative: Bool {
        Wine.isDXMTRuntimeNative(payloadRoot: dxmtFolder)
    }

    /// Whether `backend` can run on this runtime.
    public func isBackendAvailable(_ backend: GraphicsBackend) -> Bool {
        WhiskyWineInstaller.backendAvailability(
            backend,
            runtimeInfo: info,
            d3dMetalInstalled: isD3DMetalInstalled,
            dxmtRuntimeNative: isDXMTNative
        )
    }

    /// What the Recommended backend resolves to on this runtime.
    public func recommendedBackend(for launcher: LauncherType? = nil) -> GraphicsBackend {
        GraphicsBackendResolver.resolve(
            for: launcher,
            runtimeInfo: info,
            d3dMetalInstalled: isD3DMetalInstalled,
            dxmtRuntimeNative: isDXMTNative
        )
    }

    /// Deploys the imported GPTK payload into this runtime when it can run it.
    @discardableResult
    public func deployGPTKIfCapable() -> Bool {
        guard isGPTKCapable else { return false }
        return GPTKImporter.deployStoredPayloadIfPresent(
            fromStore: GPTKImporter.storeFolder,
            intoLibraryFolder: libraryFolder,
            isAppleSigned: GPTKImporter.isAppleSigned(_:identifier:)
        )
    }
}

public extension Bottle {
    /// The runtime this bottle runs on.
    var runtime: WineRuntime {
        WineRuntime.forVersion(settings.runtimeVersion)
    }
}
