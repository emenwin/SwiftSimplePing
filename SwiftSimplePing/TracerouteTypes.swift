/*
    Abstract:
    Swift types and data structures for SwiftSimpleTraceroute functionality.
 */

import Foundation
@_exported import SimpleTraceroute

#if canImport(Combine)
    import Combine
#endif

// MARK: - Core Data Types

/// Details of a single hop
public struct STracerouteHop: Sendable, Equatable, Identifiable {
    public let id = UUID()
    public let hopNumber: UInt8
    public let routerAddress: String?
    public let hostName: String?
    public let roundTripTime: TimeInterval?
    public let isDestination: Bool
    public let isTimeout: Bool
    public let timestamp: Date
    public let sequenceNumber: UInt16
    public let probeIndex: UInt8

    /// Hop status
    public enum Status: Equatable {
        case success(latency: TimeInterval)
        case timeout
        case unreachable
    }

    public var status: Status {
        if isTimeout {
            return .timeout
        } else if let rtt = roundTripTime {
            return .success(latency: rtt)
        } else {
            return .unreachable
        }
    }

    /// Formatted latency string
    public var formattedLatency: String {
        switch status {
        case .success(let latency):
            return String(format: "%.1f ms", latency * 1000)
        case .timeout:
            return "* (timeout)"
        case .unreachable:
            return "* (unreachable)"
        }
    }

    /// Formatted hop description
    public var description: String {
        let addressStr = routerAddress ?? "unknown"
        return "\(hopNumber): \(addressStr) \(formattedLatency)"
    }

    public init(
        hopNumber: UInt8,
        routerAddress: String? = nil,
        hostName: String? = nil,
        roundTripTime: TimeInterval? = nil,
        isDestination: Bool = false,
        isTimeout: Bool = false,
        timestamp: Date = Date(),
        sequenceNumber: UInt16 = 0,
        probeIndex: UInt8 = 0
    ) {
        self.hopNumber = hopNumber
        self.routerAddress = routerAddress
        self.hostName = hostName
        self.roundTripTime = roundTripTime
        self.isDestination = isDestination
        self.isTimeout = isTimeout
        self.timestamp = timestamp
        self.sequenceNumber = sequenceNumber
        self.probeIndex = probeIndex
    }
}

/// Traceroute statistics
public struct STracerouteStatistics: Sendable, Equatable {
    public let probesSent: Int
    public let responsesReceived: Int
    public let timeouts: Int
    public let lossPercentage: Double
    public let averageLatency: TimeInterval?
    public let minLatency: TimeInterval?
    public let maxLatency: TimeInterval?
    public let completedHops: Int

    public init(probesSent: Int, responsesReceived: Int, timeouts: Int, latencies: [TimeInterval]) {
        self.probesSent = probesSent
        self.responsesReceived = responsesReceived
        self.timeouts = timeouts
        self.lossPercentage = probesSent > 0 ? Double(timeouts) / Double(probesSent) * 100.0 : 0.0
        self.completedHops = responsesReceived + timeouts

        let validLatencies = latencies.filter { $0 > 0 }
        if !validLatencies.isEmpty {
            self.averageLatency = validLatencies.reduce(0, +) / Double(validLatencies.count)
            self.minLatency = validLatencies.min()
            self.maxLatency = validLatencies.max()
        } else {
            self.averageLatency = nil
            self.minLatency = nil
            self.maxLatency = nil
        }
    }

    /// Formatted packet loss rate string
    public var formattedLossPercentage: String {
        return String(format: "%.1f%%", lossPercentage)
    }

    /// Formatted average latency string
    public var formattedAverageLatency: String {
        if let avg = averageLatency {
            return String(format: "%.1f ms", avg * 1000)
        }
        return "N/A"
    }
}

/// Complete traceroute result
public struct STracerouteResult: Sendable {
    public let targetHostname: String
    public let targetAddress: String
    public let maxHops: UInt8
    public let actualHops: UInt8
    public let totalTime: TimeInterval
    public let hops: [STracerouteHop]
    public let reachedTarget: Bool
    public let statistics: STracerouteStatistics

    /// Whether successfully reached the target
    public var isSuccessful: Bool {
        return reachedTarget && actualHops > 0
    }

    /// Formatted total time string
    public var formattedTotalTime: String {
        return String(format: "%.2f seconds", totalTime)
    }

    /// Path summary description
    public var pathSummary: String {
        if isSuccessful {
            return "Reached \(targetAddress) in \(actualHops) hops (\(formattedTotalTime))"
        } else {
            return "Failed to reach \(targetAddress) after \(actualHops) hops"
        }
    }

    public init(
        targetHostname: String,
        targetAddress: String,
        maxHops: UInt8,
        actualHops: UInt8,
        totalTime: TimeInterval,
        hops: [STracerouteHop],
        reachedTarget: Bool,
        statistics: STracerouteStatistics
    ) {
        self.targetHostname = targetHostname
        self.targetAddress = targetAddress
        self.maxHops = maxHops
        self.actualHops = actualHops
        self.totalTime = totalTime
        self.hops = hops
        self.reachedTarget = reachedTarget
        self.statistics = statistics
    }
}

// MARK: - Error Types

/// SwiftSimpleTraceroute error type
public enum STracerouteError: Error, LocalizedError, Equatable {
    case invalidHostname(String)
    case resolutionFailed(underlying: String)
    case networkError(underlying: String)
    case timeout
    case cancelled
    case invalidConfiguration(String)
    case systemError(underlying: String)
    case alreadyRunning
    case notRunning

    public var errorDescription: String? {
        switch self {
        case .invalidHostname(let host):
            return "Invalid hostname: \(host)"
        case .resolutionFailed(let message):
            return "Failed to resolve hostname: \(message)"
        case .networkError(let message):
            return "Network error: \(message)"
        case .timeout:
            return "Traceroute operation timed out"
        case .cancelled:
            return "Traceroute operation was cancelled"
        case .invalidConfiguration(let message):
            return "Invalid configuration: \(message)"
        case .systemError(let message):
            return "System error: \(message)"
        case .alreadyRunning:
            return "Traceroute is already running"
        case .notRunning:
            return "Traceroute is not running"
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .invalidHostname:
            return "Please provide a valid hostname or IP address"
        case .resolutionFailed:
            return "Check your internet connection and verify the hostname"
        case .networkError:
            return "Check your network connection and try again"
        case .timeout:
            return "Try increasing the timeout value or check network connectivity"
        case .cancelled:
            return nil
        case .invalidConfiguration:
            return "Please review and correct the configuration parameters"
        case .systemError:
            return "This may be a temporary issue, please try again"
        case .alreadyRunning:
            return "Stop the current traceroute before starting a new one"
        case .notRunning:
            return "Start the traceroute before performing this operation"
        }
    }
}

// MARK: - Configuration

/// Traceroute configuration options
public struct STracerouteConfiguration: Sendable, Equatable {
    public var maxHops: UInt8
    public var timeout: TimeInterval
    public var probesPerHop: UInt8
    public var addressStyle: SimplePingAddressStyle

    public init(
        maxHops: UInt8 = 30,
        timeout: TimeInterval = 5.0,
        probesPerHop: UInt8 = 3,
        addressStyle: SimplePingAddressStyle = .any
    ) {
        self.maxHops = maxHops
        self.timeout = timeout
        self.probesPerHop = probesPerHop
        self.addressStyle = addressStyle
    }

    /// Validate the validity of the configuration
    public func validate() throws {
        guard maxHops >= 1 && maxHops <= 255 else {
            throw STracerouteError.invalidConfiguration("maxHops must be between 1 and 255")
        }
        guard timeout > 0 && timeout <= 60 else {
            throw STracerouteError.invalidConfiguration("timeout must be between 0 and 60 seconds")
        }
        guard probesPerHop >= 1 && probesPerHop <= 10 else {
            throw STracerouteError.invalidConfiguration("probesPerHop must be between 1 and 10")
        }
    }

    /// Preset configuration: quick traceroute
    public static var quick: STracerouteConfiguration {
        return STracerouteConfiguration(maxHops: 15, timeout: 3.0, probesPerHop: 1)
    }

    /// Preset configuration: detailed traceroute
    public static var detailed: STracerouteConfiguration {
        return STracerouteConfiguration(maxHops: 30, timeout: 10.0, probesPerHop: 3)
    }

    /// Preset configuration: IPv4 only
    public static var ipv4Only: STracerouteConfiguration {
        return STracerouteConfiguration(addressStyle: .icmPv4)
    }

    /// Preset configuration: IPv6 only
    public static var ipv6Only: STracerouteConfiguration {
        return STracerouteConfiguration(addressStyle: .icmPv6)
    }
}

// MARK: - Delegate Protocol

/// SwiftSimpleTraceroute delegate protocol
public protocol SwiftSimpleTracerouteDelegate: AnyObject {
    /// Traceroute successfully started
    func swiftSimpleTraceroute(
        _ traceroute: SwiftSimpleTraceroute, didStartWithAddress address: String)

    /// Traceroute failed to start
    func swiftSimpleTraceroute(
        _ traceroute: SwiftSimpleTraceroute, didFailWithError error: STracerouteError)

    /// Complete a hop
    func swiftSimpleTraceroute(
        _ traceroute: SwiftSimpleTraceroute, didCompleteHop hop: STracerouteHop)

    /// Statistics update
    func swiftSimpleTraceroute(
        _ traceroute: SwiftSimpleTraceroute, didUpdateStatistics statistics: STracerouteStatistics)

    /// Traceroute completed
    func swiftSimpleTraceroute(
        _ traceroute: SwiftSimpleTraceroute, didFinishWithResult result: STracerouteResult)
}

// MARK: - Optional Delegate Methods

extension SwiftSimpleTracerouteDelegate {
    /// Optional: Send probe packet
    public func swiftSimpleTraceroute(
        _ traceroute: SwiftSimpleTraceroute, didSendProbeToHop hopNumber: UInt8,
        sequenceNumber: UInt16
    ) {}

    /// Optional: Received response
    public func swiftSimpleTraceroute(
        _ traceroute: SwiftSimpleTraceroute, didReceiveResponseFromHop hopNumber: UInt8,
        latency: TimeInterval
    ) {}

    /// Optional: Probe timeout
    public func swiftSimpleTraceroute(
        _ traceroute: SwiftSimpleTraceroute, didTimeoutForHop hopNumber: UInt8
    ) {}
}
