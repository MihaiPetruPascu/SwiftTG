//
//  CallProtocol.swift
//  tl2swift
//
//  Generated automatically. Any changes will be lost!
//  Based on TDLib 1.8.65-a17f87c4
//  https://github.com/tdlib/td/tree/a17f87c4
//

import Foundation


/// Specifies the supported call protocols
public struct CallProtocol: Codable, Equatable, Hashable {

    private enum CodingKeys: String, CodingKey {
        case libraryVersions
        case maxLayer
        case minLayer
        case udpP2p
        case udpReflector
    }

    /// List of supported tgcalls versions
    public let libraryVersions: [String]

    /// The maximum supported API layer; use 92
    public let maxLayer: Int

    /// The minimum supported API layer; use 65
    public let minLayer: Int

    /// True, if UDP peer-to-peer connections are supported
    public let udpP2p: Bool

    /// True, if connection through UDP reflectors is supported
    public let udpReflector: Bool


    public init(
        libraryVersions: [String],
        maxLayer: Int,
        minLayer: Int,
        udpP2p: Bool,
        udpReflector: Bool
    ) {
        self.libraryVersions = libraryVersions
        self.maxLayer = maxLayer
        self.minLayer = minLayer
        self.udpP2p = udpP2p
        self.udpReflector = udpReflector
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.libraryVersions = try container.decode([String].self, forKey: .libraryVersions)
        self.maxLayer = try container.decode(Int.self, forKey: .maxLayer)
        self.minLayer = try container.decode(Int.self, forKey: .minLayer)
        self.udpP2p = try container.decodeIfPresent(Bool.self, forKey: .udpP2p) ?? false
        self.udpReflector = try container.decodeIfPresent(Bool.self, forKey: .udpReflector) ?? true
    }
}
