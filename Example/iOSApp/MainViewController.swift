/*
    Copyright (C) 2016 Apple Inc. All Rights Reserved.
    See LICENSE.txt for this sample’s licensing information

    Abstract:
    A view controller for testing SimplePing on iOS.
 */

import SwiftSimplePing
import UIKit

class MainViewController: UITableViewController {

    let hostName = "www.apple.com"

    override func viewDidLoad() {
        super.viewDidLoad()
        self.title = self.hostName
    }

    var swiftPinger: SwiftSimplePing?

    // Keep legacy properties for backward compatibility demo
    var pinger: SimplePing?
    var sendTimer: Timer?

    /// Called by the table view selection delegate callback to start the ping.

    func start(forceIPv4: Bool, forceIPv6: Bool) {
        self.pingerWillStart()

        NSLog("start")

        // Use new SwiftSimplePing wrapper
        let swiftPinger = SwiftSimplePing(hostName: self.hostName)
        self.swiftPinger = swiftPinger

        // By default we use the first IP address we get back from host resolution (.Any)
        // but these flags let the user override that.

        if forceIPv4 && !forceIPv6 {
            swiftPinger.addressStyle = .icmPv4
        } else if forceIPv6 && !forceIPv4 {
            swiftPinger.addressStyle = .icmPv6
        }

        swiftPinger.delegate = self
        swiftPinger.ping(interval: 1.0)  // Start continuous ping with 1 second interval
    }

    /// Called by the table view selection delegate callback to stop the ping.

    func stop() {
        NSLog("stop")
        self.swiftPinger?.stop()
        self.swiftPinger = nil

        self.pingerDidStop()
    }

    /// Sends a ping.
    ///
    /// Called to send a ping, both directly (as soon as the SimplePing object starts up) and
    /// via a timer (to continue sending pings periodically).

    @objc func sendPing() {
        // Legacy method - now handled automatically by SwiftSimplePing
        // self.pinger!.send(with: nil)

        // For demonstration, we can send a single ping
        self.swiftPinger?.pingOnce()
    }

    // MARK: utilities

    /// Returns the string representation of the supplied address.
    ///
    /// - parameter address: Contains a `(struct sockaddr)` with the address to render.
    ///
    /// - returns: A string representation of that address.

    static func displayAddressForAddress(address: NSData) -> String {
        var hostStr = [Int8](repeating: 0, count: Int(NI_MAXHOST))

        let success =
            getnameinfo(
                address.bytes.assumingMemoryBound(to: sockaddr.self),
                socklen_t(address.length),
                &hostStr,
                socklen_t(hostStr.count),
                nil,
                0,
                NI_NUMERICHOST
            ) == 0
        let result: String
        if success {
            result = hostStr.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
        } else {
            result = "?"
        }
        return result
    }

    /// Returns a short error string for the supplied error.
    ///
    /// - parameter error: The error to render.
    ///
    /// - returns: A short string representing that error.

    static func shortErrorFromError(error: NSError) -> String {
        if error.domain == kCFErrorDomainCFNetwork as String
            && error.code == Int(CFNetworkErrors.cfHostErrorUnknown.rawValue)
        {
            if let failureObj = error.userInfo[kCFGetAddrInfoFailureKey as String] {
                if let failureNum = failureObj as? NSNumber {
                    if failureNum.intValue != 0 {
                        let f = gai_strerror(Int32(failureNum.intValue))
                        if f != nil {
                            return String(cString: f!)
                        }
                    }
                }
            }
        }
        if let result = error.localizedFailureReason {
            return result
        }
        return error.localizedDescription
    }

    // MARK: table view delegate callback

    @IBOutlet var forceIPv4Cell: UITableViewCell!
    @IBOutlet var forceIPv6Cell: UITableViewCell!
    @IBOutlet var startStopCell: UITableViewCell!

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {

        let cell = self.tableView.cellForRow(at: indexPath as IndexPath)!
        switch cell {
        case forceIPv4Cell, forceIPv6Cell:
            cell.accessoryType = cell.accessoryType == .none ? .checkmark : .none
        case startStopCell:
            if self.swiftPinger == nil {
                let forceIPv4 = self.forceIPv4Cell.accessoryType != .none
                let forceIPv6 = self.forceIPv6Cell.accessoryType != .none
                self.start(forceIPv4: forceIPv4, forceIPv6: forceIPv6)
            } else {
                self.stop()
            }
        default:
            fatalError()
        }
        self.tableView.deselectRow(at: indexPath as IndexPath, animated: true)
    }

    func pingerWillStart() {
        self.startStopCell.textLabel!.text = "Stop…"
    }

    func pingerDidStop() {
        self.startStopCell.textLabel!.text = "Start…"
    }
}

// MARK: - SwiftSimplePingDelegate

extension MainViewController: SwiftSimplePingDelegate {

    nonisolated func swiftSimplePing(_ pinger: SwiftSimplePing, didStartWithAddress address: Data) {
        DispatchQueue.main.async {
            NSLog(
                "SwiftSimplePing started: pinging %@",
                MainViewController.displayAddressForAddress(address: address as NSData))
        }
    }

    nonisolated func swiftSimplePing(_ pinger: SwiftSimplePing, didFailWithError error: Error) {
        DispatchQueue.main.async {
            NSLog(
                "SwiftSimplePing failed: %@",
                MainViewController.shortErrorFromError(error: error as NSError))
            self.stop()
        }
    }

    nonisolated func swiftSimplePing(
        _ pinger: SwiftSimplePing, didReceivePingResult result: PingResult
    ) {
        // Extract values before entering Task to avoid sendability issues
        let isSuccess = result.isSuccess
        let sequenceNumber = result.sequenceNumber
        let latency = result.latency
        let packetSize = result.packetSize
        let error = result.error

        DispatchQueue.main.async {
            if isSuccess {
                let latencyMs = (latency! * 1000).rounded(toPlaces: 1)
                NSLog(
                    "#%u received: %.1fms, size=%d", sequenceNumber, latencyMs,
                    packetSize)
            } else {
                NSLog(
                    "#%u failed: %@", sequenceNumber,
                    MainViewController.shortErrorFromError(error: error! as NSError))
            }
        }
    }

    nonisolated func swiftSimplePing(
        _ pinger: SwiftSimplePing, didUpdateStatistics statistics: PingStatistics
    ) {
        // Extract values before entering Task to avoid sendability issues
        let lossPercentage = statistics.lossPercentage
        let averageLatency = statistics.averageLatency
        let latencies = statistics.latencies
        let packetsReceived = statistics.packetsReceived
        let packetsSent = statistics.packetsSent

        DispatchQueue.main.async {
            let lossPercent = lossPercentage.rounded(toPlaces: 1)

            // Convert average latency to milliseconds first, then round
            let avgLatencyMs = (averageLatency ?? 0.0) * 1000
            let avgLatencyMsRounded = avgLatencyMs.rounded(toPlaces: 1)

            // Debug: Print raw statistics data
            NSLog(
                "Debug - Latencies array: %@",
                latencies.map { ($0 * 1000).rounded(toPlaces: 1) })
            NSLog(
                "Debug - Average latency raw: %@", averageLatency?.description ?? "nil")
            NSLog("Debug - Average latency in ms: %.3f", avgLatencyMs)

            NSLog(
                "Stats: %d/%d packets, %.1f%% loss, avg %.1fms",
                packetsReceived, packetsSent, lossPercent, avgLatencyMsRounded
            )
        }
    }

    nonisolated func swiftSimplePingDidStop(_ pinger: SwiftSimplePing) {
        NSLog("SwiftSimplePing stopped")
    }
}
