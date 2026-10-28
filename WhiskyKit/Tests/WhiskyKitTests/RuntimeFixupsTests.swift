//
//  RuntimeFixupsTests.swift
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
import Testing
@testable import WhiskyKit

@Suite("Runtime fixups")
struct RuntimeFixupsTests {
    /// A minimal thin x86_64 dylib: one LC_LOAD_DYLIB naming `dylib` and a
    /// symbol table whose only entries are `undefinedSymbols`.
    static func machO(dylib: String, undefinedSymbols: [String]) -> Data {
        var bytes: [UInt8] = []
        func word(_ value: Int) {
            withUnsafeBytes(of: UInt32(value).littleEndian) { bytes.append(contentsOf: $0) }
        }

        let name = Array(dylib.utf8) + [0]
        let paddedName = name + [UInt8](repeating: 0, count: (8 - name.count % 8) % 8)
        let dylibCommandSize = 24 + paddedName.count
        let symbolOffset = 32 + dylibCommandSize + 24
        var strings: [UInt8] = [0]
        var nameIndices: [Int] = []
        for symbol in undefinedSymbols {
            nameIndices.append(strings.count)
            strings += Array(symbol.utf8) + [0]
        }
        let stringOffset = symbolOffset + undefinedSymbols.count * 16

        // mach_header_64: magic, x86_64, subtype, MH_DYLIB, two commands.
        [0xFEED_FACF, 0x0100_0007, 3, 6, 2, dylibCommandSize + 24, 0, 0].forEach(word)
        // LC_LOAD_DYLIB with the name right after the 24-byte command.
        [0xC, dylibCommandSize, 24, 2, 0x10000, 0x10000].forEach(word)
        bytes += paddedName
        // LC_SYMTAB.
        [0x2, 24, symbolOffset, undefinedSymbols.count, stringOffset, strings.count].forEach(word)
        // nlist_64 entries: N_UNDF | N_EXT.
        for index in nameIndices {
            word(index)
            bytes += [0x01, 0, 0, 1] + [UInt8](repeating: 0, count: 8)
        }
        bytes += strings
        return Data(bytes)
    }

    @Test("Reads dylib load commands and undefined symbols")
    func parsesLinkage() throws {
        let data = Self.machO(dylib: RuntimeFixups.bundledIconv, undefinedSymbols: ["_iconv", "_iconv_open"])
        let linkage = try #require(MachOLinkage(data))
        #expect(linkage.dylibs.map(\.name) == [RuntimeFixups.bundledIconv])
        #expect(linkage.undefinedSymbols == ["_iconv", "_iconv_open"])
    }

    @Test("Relinks in place, keeping the file size")
    func relinksInPlace() throws {
        let data = Self.machO(dylib: RuntimeFixups.bundledIconv, undefinedSymbols: ["_iconv"])
        let patched = try #require(MachOLinkage.relinking(
            data, from: RuntimeFixups.bundledIconv, to: RuntimeFixups.systemIconv
        ))
        #expect(patched.count == data.count)
        let linkage = try #require(MachOLinkage(patched))
        #expect(linkage.dylibs.map(\.name) == [RuntimeFixups.systemIconv])
        #expect(linkage.undefinedSymbols == ["_iconv"])
    }

    @Test("Leaves a library alone when it does not link the old name")
    func ignoresOtherLibraries() {
        let data = Self.machO(dylib: "/usr/lib/libSystem.B.dylib", undefinedSymbols: ["_iconv"])
        #expect(MachOLinkage.relinking(data, from: RuntimeFixups.bundledIconv, to: RuntimeFixups.systemIconv) == nil)
    }

    @Test("Refuses a name that does not fit the load command")
    func refusesLongerName() {
        let data = Self.machO(dylib: "/a.dylib", undefinedSymbols: [])
        #expect(MachOLinkage.relinking(data, from: "/a.dylib", to: "/a/much/longer/install/name.dylib") == nil)
    }

    @Test("Is not fooled by data that is not a 64-bit Mach-O")
    func rejectsOtherData() {
        #expect(MachOLinkage(Data("not a binary at all, just text".utf8)) == nil)
        #expect(MachOLinkage(Data()) == nil)
    }

    @Test("Only libraries importing _iconv need the relink")
    func findsLibrariesNeedingTheRelink() throws {
        let libraries = FileManager.default.temporaryDirectory.appending(path: "RuntimeFixups-\(UUID().uuidString)")
        let wine = libraries.appending(path: "Wine")
        let lib = wine.appending(path: "lib")
        try FileManager.default.createDirectory(at: lib, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: libraries) }

        let bundled = RuntimeFixups.bundledIconv
        try Self.machO(dylib: bundled, undefinedSymbols: ["_iconv"]).write(to: lib.appending(path: "libglib.dylib"))
        try Self.machO(dylib: bundled, undefinedSymbols: ["_libiconv"]).write(to: lib.appending(path: "libidn2.dylib"))
        try Self.machO(dylib: "/usr/lib/libz.dylib", undefinedSymbols: ["_iconv"])
            .write(to: lib.appending(path: "libz.dylib"))
        try Data("text".utf8).write(to: lib.appending(path: "notes.so"))

        let found = RuntimeFixups.librariesNeedingIconvRelink(in: wine).map(\.lastPathComponent)
        #expect(found == ["libglib.dylib"])
        #expect(RuntimeFixups.pending([.systemLibiconv], inRuntimeAt: libraries) == [.systemLibiconv])

        try FileManager.default.removeItem(at: lib.appending(path: "libglib.dylib"))
        #expect(RuntimeFixups.pending([.systemLibiconv], inRuntimeAt: libraries).isEmpty)
    }
}
