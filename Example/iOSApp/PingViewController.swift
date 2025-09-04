/*
    Copyright (C) 2016 Apple Inc. All Rights Reserved.
    See LICENSE.txt for this sample’s licensing information

    Abstract:
    A view controller for testing SimplePing on iOS.
 */

import SwiftSimplePing
import UIKit

class PingViewController: UITableViewController {

    // MARK: Init (pure code style)
    convenience init() {
        if #available(iOS 13.0, *) {
            self.init(style: .insetGrouped)
        } else {
            self.init(style: .grouped)
        }
    }
    override init(style: UITableView.Style) {
        super.init(style: style)
    }
    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    let hostName = "www.apple.com"

    override func viewDidLoad() {
        super.viewDidLoad()
        self.title = self.hostName
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "Cell")
        tableView.allowsSelection = true
    }

    var swiftPinger: SwiftSimplePing?

    // Legacy demo properties (kept for compatibility with documentation comments)
    var pinger: SimplePing?
    var sendTimer: Timer?

    // UI state
    private var forceIPv4 = false
    private var forceIPv6 = false

    // Row definitions
    private enum Row: Int, CaseIterable {
        case forceIPv4 = 0
        case forceIPv6 = 1
        case startStop = 2
    }
    private func indexPath(for row: Row) -> IndexPath { IndexPath(row: row.rawValue, section: 0) }

    // MARK: - Start/Stop

    func start(forceIPv4: Bool, forceIPv6: Bool) {
        self.pingerWillStart()
        NSLog("start")

        let swiftPinger = SwiftSimplePing(hostName: self.hostName)
        self.swiftPinger = swiftPinger

        if forceIPv4 && !forceIPv6 {
            swiftPinger.addressStyle = .icmPv4
        } else if forceIPv6 && !forceIPv4 {
            swiftPinger.addressStyle = .icmPv6
        }

        swiftPinger.delegate = self
        swiftPinger.ping(interval: 1.0)  // 1 second continuous ping
    }

    func stop() {
        NSLog("stop")
        self.swiftPinger?.stop()
        self.swiftPinger = nil
        self.pingerDidStop()
    }

    @objc func sendPing() {
        self.swiftPinger?.pingOnce()
    }

    // MARK: utilities (keep original utility methods)

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

    // MARK: - UITableView DataSource

    override func numberOfSections(in tableView: UITableView) -> Int {
        1
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        Row.allCases.count
    }

    override func tableView(
        _ tableView: UITableView,
        cellForRowAt indexPath: IndexPath
    ) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "Cell", for: indexPath)

        guard let row = Row(rawValue: indexPath.row) else { return cell }
        cell.selectionStyle = .default
        cell.textLabel?.textAlignment = .natural
        cell.accessoryType = .none

        switch row {
        case .forceIPv4:
            cell.textLabel?.text = "Force IPv4"
            cell.accessoryType = forceIPv4 ? .checkmark : .none
        case .forceIPv6:
            cell.textLabel?.text = "Force IPv6"
            cell.accessoryType = forceIPv6 ? .checkmark : .none
        case .startStop:
            cell.textLabel?.text = (swiftPinger == nil) ? "Start…" : "Stop…"
            cell.textLabel?.textAlignment = .center
        }
        return cell
    }

    // MARK: - UITableView Delegate

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        guard let row = Row(rawValue: indexPath.row) else { return }

        switch row {
        case .forceIPv4:
            forceIPv4.toggle()
            tableView.reloadRows(at: [indexPath], with: .automatic)
        case .forceIPv6:
            forceIPv6.toggle()
            tableView.reloadRows(at: [indexPath], with: .automatic)
        case .startStop:
            if self.swiftPinger == nil {
                self.start(forceIPv4: forceIPv4, forceIPv6: forceIPv6)
            } else {
                self.stop()
            }
            tableView.reloadRows(at: [indexPath], with: .automatic)
        }

        tableView.deselectRow(at: indexPath, animated: true)
    }

    func pingerWillStart() {
        // Update Start/Stop row
        tableView.reloadRows(at: [indexPath(for: .startStop)], with: .none)
    }

    func pingerDidStop() {
        // Update Start/Stop row
        tableView.reloadRows(at: [indexPath(for: .startStop)], with: .none)
    }
}

// MARK: - SwiftSimplePingDelegate

extension PingViewController: SwiftSimplePingDelegate {

    nonisolated func swiftSimplePing(_ pinger: SwiftSimplePing, didStartWithAddress address: Data) {
        DispatchQueue.main.async {
            NSLog(
                "SwiftSimplePing started: pinging %@",
                PingViewController.displayAddressForAddress(address: address as NSData))
        }
    }

    nonisolated func swiftSimplePing(_ pinger: SwiftSimplePing, didFailWithError error: Error) {
        DispatchQueue.main.async {
            NSLog(
                "SwiftSimplePing failed: %@",
                PingViewController.shortErrorFromError(error: error as NSError))
            self.stop()
        }
    }

    nonisolated func swiftSimplePing(
        _ pinger: SwiftSimplePing, didReceivePingResult result: PingResult
    ) {
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
                    PingViewController.shortErrorFromError(error: error! as NSError))
            }
        }
    }

    nonisolated func swiftSimplePing(
        _ pinger: SwiftSimplePing, didUpdateStatistics statistics: PingStatistics
    ) {
        let lossPercentage = statistics.lossPercentage
        let averageLatency = statistics.averageLatency
        let latencies = statistics.latencies
        let packetsReceived = statistics.packetsReceived
        let packetsSent = statistics.packetsSent

        DispatchQueue.main.async {
            let lossPercent = lossPercentage.rounded(toPlaces: 1)
            let avgLatencyMs = (averageLatency ?? 0.0) * 1000
            let avgLatencyMsRounded = avgLatencyMs.rounded(toPlaces: 1)

            NSLog("Debug - Latencies array: %@", latencies.map { ($0 * 1000).rounded(toPlaces: 1) })
            NSLog("Debug - Average latency raw: %@", averageLatency?.description ?? "nil")
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
