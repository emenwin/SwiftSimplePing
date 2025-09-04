/*
    Abstract:
    A custom table view cell for displaying traceroute hop results.
 */

import SwiftSimplePing
import UIKit

class TracerouteHopCell: UITableViewCell {

    // MARK: - UI Elements

    private let hopNumberLabel: UILabel = {
        let label = UILabel()
        label.font = .boldSystemFont(ofSize: 16)
        label.textColor = .label
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentHuggingPriority(.required, for: .horizontal)
        return label
    }()

    private let routerAddressLabel: UILabel = {
        let label = UILabel()
        label.font = .systemFont(ofSize: 14)
        label.textColor = .label
        label.numberOfLines = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private let latencyLabel: UILabel = {
        let label = UILabel()
        label.font = .monospacedDigitSystemFont(ofSize: 14, weight: .regular)
        label.textColor = .secondaryLabel
        label.textAlignment = .right
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentHuggingPriority(.required, for: .horizontal)
        return label
    }()

    private let statusImageView: UIImageView = {
        let imageView = UIImageView()
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.setContentHuggingPriority(.required, for: .horizontal)
        return imageView
    }()

    private let probeDetailsLabel: UILabel = {
        let label = UILabel()
        label.font = .systemFont(ofSize: 12)
        label.textColor = .tertiaryLabel
        label.numberOfLines = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    // MARK: - Initialization

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        setupUI()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupUI()
    }

    // MARK: - Setup

    private func setupUI() {
        selectionStyle = .none

        // Add subviews
        contentView.addSubview(hopNumberLabel)
        contentView.addSubview(statusImageView)
        contentView.addSubview(routerAddressLabel)
        contentView.addSubview(latencyLabel)
        contentView.addSubview(probeDetailsLabel)

        // Setup constraints
        NSLayoutConstraint.activate([
            // Hop number label - top left
            hopNumberLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            hopNumberLabel.leadingAnchor.constraint(
                equalTo: contentView.leadingAnchor, constant: 16),
            hopNumberLabel.widthAnchor.constraint(equalToConstant: 40),

            // Status image - next to hop number
            statusImageView.centerYAnchor.constraint(equalTo: hopNumberLabel.centerYAnchor),
            statusImageView.leadingAnchor.constraint(
                equalTo: hopNumberLabel.trailingAnchor, constant: 8),
            statusImageView.widthAnchor.constraint(equalToConstant: 16),
            statusImageView.heightAnchor.constraint(equalToConstant: 16),

            // Router address label - main content area
            routerAddressLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            routerAddressLabel.leadingAnchor.constraint(
                equalTo: statusImageView.trailingAnchor, constant: 8),
            routerAddressLabel.trailingAnchor.constraint(
                equalTo: latencyLabel.leadingAnchor, constant: -8),

            // Latency label - top right
            latencyLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            latencyLabel.trailingAnchor.constraint(
                equalTo: contentView.trailingAnchor, constant: -16),
            latencyLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 80),

            // Probe details label - bottom, full width
            probeDetailsLabel.topAnchor.constraint(
                equalTo: routerAddressLabel.bottomAnchor, constant: 4),
            probeDetailsLabel.leadingAnchor.constraint(equalTo: hopNumberLabel.leadingAnchor),
            probeDetailsLabel.trailingAnchor.constraint(equalTo: latencyLabel.trailingAnchor),
            probeDetailsLabel.bottomAnchor.constraint(
                equalTo: contentView.bottomAnchor, constant: -12),
        ])
    }

    // MARK: - Configuration

    func configure(with hop: STracerouteHop) {
        // Configure hop number
        hopNumberLabel.text = "\(hop.hopNumber)"

        // Configure status and address
        if hop.isTimeout {
            configureTimeoutState()
        } else if hop.isDestination {
            configureDestinationState(hop: hop)
        } else {
            configureIntermediateState(hop: hop)
        }

        // Configure latency
        configureLatency(hop: hop)

        // Configure probe details
        configureProbeDetails(hop: hop)
    }

    private func configureTimeoutState() {
        statusImageView.image = UIImage(systemName: "clock.fill")
        statusImageView.tintColor = .systemRed
        routerAddressLabel.text = "* * * Request timed out"
        routerAddressLabel.textColor = .secondaryLabel
    }

    private func configureDestinationState(hop: STracerouteHop) {
        statusImageView.image = UIImage(systemName: "checkmark.circle.fill")
        statusImageView.tintColor = .systemGreen

        if let address = hop.routerAddress {
            routerAddressLabel.text = "\(address) (Destination)"
            routerAddressLabel.textColor = .label
        } else {
            routerAddressLabel.text = "Destination reached"
            routerAddressLabel.textColor = .label
        }
    }

    private func configureIntermediateState(hop: STracerouteHop) {
        statusImageView.image = UIImage(systemName: "arrow.right.circle.fill")
        statusImageView.tintColor = .systemBlue

        if let address = hop.routerAddress {
            routerAddressLabel.text = address
            routerAddressLabel.textColor = .label
        } else {
            routerAddressLabel.text = "Unknown router"
            routerAddressLabel.textColor = .secondaryLabel
        }
    }

    private func configureLatency(hop: STracerouteHop) {
        if hop.isTimeout {
            latencyLabel.text = "—"
            latencyLabel.textColor = .secondaryLabel
        } else if let roundTripTime = hop.roundTripTime {
            let latencyMs = (roundTripTime * 1000.0).rounded(toPlaces: 1)
            latencyLabel.text = "\(latencyMs)ms"

            // Color code latency
            if latencyMs < 50 {
                latencyLabel.textColor = .systemGreen
            } else if latencyMs < 200 {
                latencyLabel.textColor = .systemOrange
            } else {
                latencyLabel.textColor = .systemRed
            }
        }
    }

    private func configureProbeDetails(hop: STracerouteHop) {
        var details: [String] = []

        // Add sequence number if available
        if hop.sequenceNumber > 0 {
            details.append("Seq: \(hop.sequenceNumber)")
        }

        // Add probe index if available
        if hop.probeIndex > 0 {
            details.append("Probe: \(hop.probeIndex)")
        }

        // Add timestamp info
        let formatter = DateFormatter()
        formatter.timeStyle = .medium
        formatter.dateStyle = .none
        details.append("Time: \(formatter.string(from: hop.timestamp))")

        // Add additional status info
        if hop.isDestination {
            details.append("Target reached")
        } else if hop.isTimeout, let roundTripTime = hop.roundTripTime {
            details.append("Timeout after \(roundTripTime.rounded(toPlaces: 1))s")
        }

        probeDetailsLabel.text = details.joined(separator: " • ")
    }

    // MARK: - Reuse

    override func prepareForReuse() {
        super.prepareForReuse()

        hopNumberLabel.text = nil
        routerAddressLabel.text = nil
        latencyLabel.text = nil
        probeDetailsLabel.text = nil
        statusImageView.image = nil
        statusImageView.tintColor = nil
        routerAddressLabel.textColor = .label
        latencyLabel.textColor = .secondaryLabel
    }
}
