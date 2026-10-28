//
//  RuntimeFixups.swift
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

private let logger = Logger(subsystem: Bundle.whiskyBundleIdentifier, category: "RuntimeFixups")

/// Fixes applied to a downloaded runtime before it is installed.
///
/// Runtimes are third-party builds, and a few ship defects that only show when
/// a game reaches the broken part. Each fix is narrow, checks the bytes it
/// expects before touching anything, and is a no-op on a runtime without the
/// defect.
public enum RuntimeFixups {
    static let bundledIconv = "@loader_path/./libiconv.2.dylib"
    static let systemIconv = "/usr/lib/libiconv.2.dylib"

    /// Applies `fixups` to the runtime whose `Libraries` folder is given.
    ///
    /// - Returns: The files that were changed.
    @discardableResult
    public static func apply(_ fixups: [RuntimeFixup], toRuntimeAt libraries: URL) throws -> [URL] {
        var changed: [URL] = []
        for fixup in fixups {
            switch fixup {
            case .systemLibiconv:
                changed += try relinkBundledIconv(in: libraries.appending(path: "Wine"))
            }
        }
        return changed
    }

    /// The fixups in `fixups` the runtime still needs, without changing anything.
    public static func pending(_ fixups: [RuntimeFixup], inRuntimeAt libraries: URL) -> [RuntimeFixup] {
        fixups.filter { fixup in
            switch fixup {
            case .systemLibiconv:
                !librariesNeedingIconvRelink(in: libraries.appending(path: "Wine")).isEmpty
            }
        }
    }

    /// Relinks libraries that import `_iconv` from the bundled libiconv against
    /// the system one.
    ///
    /// Runtime 4.0.0-beta.2 links glib, ffmpeg and a few others against its
    /// bundled libiconv, which only exports the `_libiconv*` names, while they
    /// import `_iconv*`. dlopen fails, so GStreamer and winedmo never load: no
    /// H.264 decoder, and a game that plays video crashes on the first one.
    /// Later runtimes link these against `/usr/lib/libiconv.2.dylib`, which
    /// exports `_iconv*`; this does the same. The system path is shorter than the
    /// bundled one, so the load command is rewritten in place, and the library
    /// is then re-signed ad hoc. Libraries that import `_libiconv*` keep the
    /// bundled copy.
    ///
    /// - Returns: The libraries that were relinked.
    @discardableResult
    public static func relinkBundledIconv(in wineFolder: URL) throws -> [URL] {
        var relinked: [URL] = []
        for library in librariesNeedingIconvRelink(in: wineFolder) {
            let data = try Data(contentsOf: library)
            guard let patched = MachOLinkage.relinking(data, from: bundledIconv, to: systemIconv) else { continue }
            try replaceContents(of: library, with: patched)
            try resign(library)
            logger.info("Relinked \(library.lastPathComponent, privacy: .public) to the system libiconv")
            relinked.append(library)
        }
        return relinked
    }

    /// Libraries under `wineFolder` that link the bundled libiconv and import
    /// `_iconv` from it.
    static func librariesNeedingIconvRelink(in wineFolder: URL) -> [URL] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey]
        guard let enumerator = FileManager.default.enumerator(at: wineFolder, includingPropertiesForKeys: keys)
        else { return [] }

        var found: [URL] = []
        for case let url as URL in enumerator {
            guard ["dylib", "so"].contains(url.pathExtension),
                  let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true, values.isSymbolicLink != true,
                  headerMentions(bundledIconv, in: url),
                  let data = try? Data(contentsOf: url, options: .mappedIfSafe),
                  let linkage = MachOLinkage(data),
                  linkage.dylibs.contains(where: { $0.name == bundledIconv }),
                  linkage.undefinedSymbols.contains("_iconv")
            else { continue }
            found.append(url)
        }
        return found
    }

    /// Whether `name` appears in the first 64 KB of `url`, where the load
    /// commands live. Keeps a scan of the whole runtime from reading every
    /// library in full.
    private static func headerMentions(_ name: String, in url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 64 * 1024) else { return false }
        return header.range(of: Data(name.utf8)) != nil
    }

    /// Writes `data` over `url`, keeping its permissions.
    private static func replaceContents(of url: URL, with data: Data) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))
        try data.write(to: url, options: .atomic)
        if let permissions = attributes[.posixPermissions] {
            try FileManager.default.setAttributes(
                [.posixPermissions: permissions], ofItemAtPath: url.path(percentEncoded: false)
            )
        }
    }

    /// Rewriting a load command invalidates the existing signature, and an
    /// invalid one is worse than none: the loader refuses it.
    private static func resign(_ url: URL) throws {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/codesign")
        process.arguments = ["--force", "--sign", "-", url.path(percentEncoded: false)]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw RuntimeFixupError.resignFailed(url.lastPathComponent)
        }
    }
}

/// Errors from ``RuntimeFixups``.
public enum RuntimeFixupError: LocalizedError, Equatable {
    case resignFailed(String)

    public var errorDescription: String? {
        switch self {
        case let .resignFailed(name):
            String(format: String(localized: "runtimeFixup.error.resignFailed"), name)
        }
    }
}

/// The parts of a thin 64-bit Mach-O that ``RuntimeFixups`` reads and rewrites:
/// the dylib load commands and the undefined symbols in the symbol table.
struct MachOLinkage {
    struct DylibReference: Equatable {
        /// The install name the load command carries.
        let name: String
        /// Where the name starts in the file.
        let nameOffset: Int
        /// The bytes the load command reserves for the name, terminator included.
        let capacity: Int
    }

    private static let magic64: UInt32 = 0xFEED_FACF
    private static let headerSize = 32
    private static let symtabCommand: UInt32 = 0x2
    /// LC_LOAD_DYLIB, LC_LOAD_WEAK_DYLIB, LC_REEXPORT_DYLIB, LC_LAZY_LOAD_DYLIB
    /// and LC_LOAD_UPWARD_DYLIB, which all carry a `dylib_command`.
    private static let dylibCommands: Set<UInt32> = [0xC, 0x8000_0018, 0x8000_001F, 0x20, 0x8000_0023]
    private static let nlistSize = 16

    let dylibs: [DylibReference]
    let undefinedSymbols: Set<String>

    /// Parses `data`, or returns `nil` if it is not a thin 64-bit Mach-O.
    init?(_ data: Data) {
        let bytes = [UInt8](data)
        guard bytes.count >= Self.headerSize, Self.readUInt32(bytes, at: 0) == Self.magic64 else { return nil }

        let commandCount = Int(Self.readUInt32(bytes, at: 16))
        var offset = Self.headerSize
        var dylibs: [DylibReference] = []
        var undefined: Set<String> = []

        for _ in 0 ..< commandCount {
            guard offset + 8 <= bytes.count else { return nil }
            let command = Self.readUInt32(bytes, at: offset)
            let size = Int(Self.readUInt32(bytes, at: offset + 4))
            guard size >= 8, offset + size <= bytes.count else { return nil }

            if Self.dylibCommands.contains(command), size >= 12 {
                let nameStart = Int(Self.readUInt32(bytes, at: offset + 8))
                if nameStart < size {
                    let start = offset + nameStart
                    let end = bytes[start ..< offset + size].firstIndex(of: 0) ?? offset + size
                    dylibs.append(DylibReference(
                        name: String(decoding: bytes[start ..< end], as: UTF8.self),
                        nameOffset: start,
                        capacity: size - nameStart
                    ))
                }
            } else if command == Self.symtabCommand, size >= 24 {
                undefined = Self.undefinedSymbols(
                    in: bytes,
                    symbolOffset: Int(Self.readUInt32(bytes, at: offset + 8)),
                    symbolCount: Int(Self.readUInt32(bytes, at: offset + 12)),
                    stringOffset: Int(Self.readUInt32(bytes, at: offset + 16)),
                    stringSize: Int(Self.readUInt32(bytes, at: offset + 20))
                )
            }
            offset += size
        }

        self.dylibs = dylibs
        self.undefinedSymbols = undefined
    }

    /// Returns `data` with every load command naming `oldName` pointing at
    /// `newName` instead, or `nil` when there is nothing to change or the new
    /// name does not fit the space the command reserves.
    static func relinking(_ data: Data, from oldName: String, to newName: String) -> Data? {
        guard let linkage = MachOLinkage(data) else { return nil }
        let references = linkage.dylibs.filter { $0.name == oldName }
        let replacement = Array(newName.utf8)
        guard !references.isEmpty, references.allSatisfy({ replacement.count < $0.capacity }) else { return nil }

        var patched = data
        for reference in references {
            let padding = [UInt8](repeating: 0, count: reference.capacity - replacement.count)
            patched.replaceSubrange(
                reference.nameOffset ..< reference.nameOffset + reference.capacity,
                with: replacement + padding
            )
        }
        return patched
    }

    /// External undefined symbols: `N_UNDF` with `N_EXT` set and no stab bits.
    private static func undefinedSymbols(
        in bytes: [UInt8], symbolOffset: Int, symbolCount: Int, stringOffset: Int, stringSize: Int
    ) -> Set<String> {
        guard symbolOffset + symbolCount * nlistSize <= bytes.count,
              stringOffset + stringSize <= bytes.count
        else { return [] }

        var names: Set<String> = []
        for index in 0 ..< symbolCount {
            let entry = symbolOffset + index * nlistSize
            let type = bytes[entry + 4]
            guard type & 0xE0 == 0, type & 0x0E == 0, type & 0x01 != 0 else { continue }
            let nameIndex = Int(readUInt32(bytes, at: entry))
            guard nameIndex < stringSize else { continue }
            let start = stringOffset + nameIndex
            let end = bytes[start ..< stringOffset + stringSize].firstIndex(of: 0) ?? stringOffset + stringSize
            names.insert(String(decoding: bytes[start ..< end], as: UTF8.self))
        }
        return names
    }

    private static func readUInt32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        UInt32(bytes[offset])
            | UInt32(bytes[offset + 1]) << 8
            | UInt32(bytes[offset + 2]) << 16
            | UInt32(bytes[offset + 3]) << 24
    }
}
