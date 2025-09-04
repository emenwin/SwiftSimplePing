/*
    Abstract:
    A view controller for testing SimpleTraceroute on iOS.
 */

import SwiftSimplePing
import UIKit

class TracerouteViewController: UIViewController {

    // MARK: - UI Components

    private let scrollView = UIScrollView()
    private let contentView = UIView()

    // Input section
    private let hostNameTextField = UITextField()
    private let maxHopsTextField = UITextField()
    private let timeoutTextField = UITextField()
    private let probesPerHopTextField = UITextField()
    private let forceIPv4Switch = UISwitch()
    private let forceIPv6Switch = UISwitch()

    // Control section
    private let startStopButton = UIButton(type: .system)
    private let progressLabel = UILabel()
    private let statisticsLabel = UILabel()

    // Results section
    private let tableView = UITableView()

    // MARK: - Properties

    private var swiftTraceroute: SwiftSimpleTraceroute?
    private var tracerouteResults: [STracerouteHop] = []
    private var isRunning: Bool = false {
        didSet {
            updateUI()
        }
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        setupViews()
        setupConstraints()
        setupActions()
        updateUI()
    }

    // MARK: - Setup

    private func setupViews() {
        view.backgroundColor = .systemBackground
        title = "Traceroute Demo"

        // Configure scroll view
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        contentView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)
        scrollView.addSubview(contentView)

        setupInputSection()
        setupControlSection()
        setupResultsSection()
    }

    private func setupInputSection() {
        // Create input section container
        let inputStackView = UIStackView()
        inputStackView.axis = .vertical
        inputStackView.spacing = 16
        inputStackView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(inputStackView)

        // Hostname field
        let hostNameSection = createLabeledTextField(
            label: "Hostname or IP:",
            textField: hostNameTextField,
            placeholder: "www.apple.com",
            defaultValue: "www.apple.com"
        )
        inputStackView.addArrangedSubview(hostNameSection)

        // Configuration fields
        let configStackView = UIStackView()
        configStackView.axis = .horizontal
        configStackView.distribution = .fillEqually
        configStackView.spacing = 12

        let maxHopsSection = createLabeledTextField(
            label: "Max Hops:",
            textField: maxHopsTextField,
            placeholder: "30",
            defaultValue: "30"
        )
        maxHopsTextField.keyboardType = .numberPad

        let timeoutSection = createLabeledTextField(
            label: "Timeout:",
            textField: timeoutTextField,
            placeholder: "5.0",
            defaultValue: "5.0"
        )
        timeoutTextField.keyboardType = .decimalPad

        let probesSection = createLabeledTextField(
            label: "Probes:",
            textField: probesPerHopTextField,
            placeholder: "3",
            defaultValue: "3"
        )
        probesPerHopTextField.keyboardType = .numberPad

        configStackView.addArrangedSubview(maxHopsSection)
        configStackView.addArrangedSubview(timeoutSection)
        configStackView.addArrangedSubview(probesSection)
        inputStackView.addArrangedSubview(configStackView)

        // IP version switches
        let ipVersionStackView = UIStackView()
        ipVersionStackView.axis = .horizontal
        ipVersionStackView.distribution = .fillEqually
        ipVersionStackView.spacing = 20

        let ipv4Section = createLabeledSwitch(label: "Force IPv4", switch: forceIPv4Switch)
        let ipv6Section = createLabeledSwitch(label: "Force IPv6", switch: forceIPv6Switch)

        ipVersionStackView.addArrangedSubview(ipv4Section)
        ipVersionStackView.addArrangedSubview(ipv6Section)
        inputStackView.addArrangedSubview(ipVersionStackView)

        // Position input stack view
        NSLayoutConstraint.activate([
            inputStackView.topAnchor.constraint(
                equalTo: contentView.safeAreaLayoutGuide.topAnchor, constant: 20),
            inputStackView.leadingAnchor.constraint(
                equalTo: contentView.leadingAnchor, constant: 20),
            inputStackView.trailingAnchor.constraint(
                equalTo: contentView.trailingAnchor, constant: -20),
        ])

        // Add input accessory views to numeric fields
        addToolbarToNumberFields()
    }

    private func setupControlSection() {
        // Configure start/stop button
        startStopButton.translatesAutoresizingMaskIntoConstraints = false
        startStopButton.setTitle("Start Traceroute", for: .normal)
        startStopButton.backgroundColor = .systemBlue
        startStopButton.setTitleColor(.white, for: .normal)
        startStopButton.layer.cornerRadius = 8
        startStopButton.titleLabel?.font = .boldSystemFont(ofSize: 18)
        contentView.addSubview(startStopButton)

        // Configure progress label
        progressLabel.translatesAutoresizingMaskIntoConstraints = false
        progressLabel.text = "Ready to start traceroute"
        progressLabel.font = .systemFont(ofSize: 16)
        progressLabel.textColor = .label
        progressLabel.numberOfLines = 0
        contentView.addSubview(progressLabel)

        // Configure statistics label
        statisticsLabel.translatesAutoresizingMaskIntoConstraints = false
        statisticsLabel.text = ""
        statisticsLabel.font = .systemFont(ofSize: 14)
        statisticsLabel.textColor = .secondaryLabel
        statisticsLabel.numberOfLines = 0
        contentView.addSubview(statisticsLabel)
    }

    private func setupResultsSection() {
        // Configure table view
        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.delegate = self
        tableView.dataSource = self
        tableView.register(TracerouteHopCell.self, forCellReuseIdentifier: "TracerouteHopCell")
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 80
        tableView.backgroundColor = .systemBackground
        tableView.layer.cornerRadius = 8
        tableView.layer.borderWidth = 1
        tableView.layer.borderColor = UIColor.separator.cgColor
        contentView.addSubview(tableView)
    }

    private func setupConstraints() {
        let safeArea = view.safeAreaLayoutGuide
        let contentSafeArea = contentView.safeAreaLayoutGuide

        // Scroll view constraints
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: safeArea.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: safeArea.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: safeArea.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: safeArea.bottomAnchor),

            contentView.topAnchor.constraint(equalTo: scrollView.topAnchor),
            contentView.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            contentView.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor),
            contentView.widthAnchor.constraint(equalTo: scrollView.widthAnchor),
        ])

        // Find the input stack view (first subview of contentView)
        let inputStackView = contentView.subviews.first { $0 is UIStackView }!

        // Control section constraints
        NSLayoutConstraint.activate([
            startStopButton.topAnchor.constraint(
                equalTo: inputStackView.bottomAnchor, constant: 30),
            startStopButton.leadingAnchor.constraint(
                equalTo: contentView.leadingAnchor, constant: 20),
            startStopButton.trailingAnchor.constraint(
                equalTo: contentView.trailingAnchor, constant: -20),
            startStopButton.heightAnchor.constraint(equalToConstant: 50),

            progressLabel.topAnchor.constraint(equalTo: startStopButton.bottomAnchor, constant: 16),
            progressLabel.leadingAnchor.constraint(
                equalTo: contentView.leadingAnchor, constant: 20),
            progressLabel.trailingAnchor.constraint(
                equalTo: contentView.trailingAnchor, constant: -20),

            statisticsLabel.topAnchor.constraint(equalTo: progressLabel.bottomAnchor, constant: 8),
            statisticsLabel.leadingAnchor.constraint(
                equalTo: contentView.leadingAnchor, constant: 20),
            statisticsLabel.trailingAnchor.constraint(
                equalTo: contentView.trailingAnchor, constant: -20),

            tableView.topAnchor.constraint(equalTo: statisticsLabel.bottomAnchor, constant: 20),
            tableView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            tableView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            tableView.heightAnchor.constraint(equalToConstant: 400),
            tableView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -20),
        ])
    }

    private func setupActions() {
        startStopButton.addTarget(
            self, action: #selector(startStopButtonTapped), for: .touchUpInside)
        forceIPv4Switch.addTarget(
            self, action: #selector(ipVersionSwitchChanged(_:)), for: .valueChanged)
        forceIPv6Switch.addTarget(
            self, action: #selector(ipVersionSwitchChanged(_:)), for: .valueChanged)

        // Set text field delegates
        hostNameTextField.delegate = self
        maxHopsTextField.delegate = self
        timeoutTextField.delegate = self
        probesPerHopTextField.delegate = self
    }

    private func createLabeledTextField(
        label: String, textField: UITextField, placeholder: String, defaultValue: String
    ) -> UIView {
        let container = UIView()
        container.translatesAutoresizingMaskIntoConstraints = false

        let labelView = UILabel()
        labelView.text = label
        labelView.font = .systemFont(ofSize: 16, weight: .medium)
        labelView.translatesAutoresizingMaskIntoConstraints = false

        textField.placeholder = placeholder
        textField.text = defaultValue
        textField.borderStyle = .roundedRect
        textField.font = .systemFont(ofSize: 16)
        textField.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(labelView)
        container.addSubview(textField)

        NSLayoutConstraint.activate([
            labelView.topAnchor.constraint(equalTo: container.topAnchor),
            labelView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            labelView.trailingAnchor.constraint(equalTo: container.trailingAnchor),

            textField.topAnchor.constraint(equalTo: labelView.bottomAnchor, constant: 4),
            textField.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            textField.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            textField.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            textField.heightAnchor.constraint(equalToConstant: 44),
        ])

        return container
    }

    private func createLabeledSwitch(label: String, switch: UISwitch) -> UIView {
        let container = UIView()
        container.translatesAutoresizingMaskIntoConstraints = false

        let labelView = UILabel()
        labelView.text = label
        labelView.font = .systemFont(ofSize: 16, weight: .medium)
        labelView.translatesAutoresizingMaskIntoConstraints = false

        `switch`.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(labelView)
        container.addSubview(`switch`)

        NSLayoutConstraint.activate([
            labelView.topAnchor.constraint(equalTo: container.topAnchor),
            labelView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            labelView.trailingAnchor.constraint(equalTo: container.trailingAnchor),

            `switch`.topAnchor.constraint(equalTo: labelView.bottomAnchor, constant: 8),
            `switch`.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            `switch`.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        return container
    }

    private func addToolbarToNumberFields() {
        let toolbar = UIToolbar()
        toolbar.sizeToFit()

        let doneButton = UIBarButtonItem(
            barButtonSystemItem: .done,
            target: self,
            action: #selector(dismissKeyboard)
        )

        let flexSpace = UIBarButtonItem(
            barButtonSystemItem: .flexibleSpace,
            target: nil,
            action: nil
        )

        toolbar.items = [flexSpace, doneButton]

        maxHopsTextField.inputAccessoryView = toolbar
        timeoutTextField.inputAccessoryView = toolbar
        probesPerHopTextField.inputAccessoryView = toolbar
    }

    // MARK: - UI Updates

    private func updateUI() {
        DispatchQueue.main.async {
            self.startStopButton.setTitle(
                self.isRunning ? "Stop" : "Start Traceroute", for: .normal)
            self.startStopButton.backgroundColor = self.isRunning ? .systemRed : .systemBlue

            // Disable/enable input fields
            let inputsEnabled = !self.isRunning
            self.hostNameTextField.isEnabled = inputsEnabled
            self.maxHopsTextField.isEnabled = inputsEnabled
            self.timeoutTextField.isEnabled = inputsEnabled
            self.probesPerHopTextField.isEnabled = inputsEnabled
            self.forceIPv4Switch.isEnabled = inputsEnabled
            self.forceIPv6Switch.isEnabled = inputsEnabled
        }
    }

    private func updateProgress(currentHop: UInt8, maxHops: UInt8) {
        DispatchQueue.main.async {
            self.progressLabel.text = "Tracing hop \(currentHop) of \(maxHops)..."
        }
    }

    private func updateStatistics(_ statistics: STracerouteStatistics) {
        DispatchQueue.main.async {
            let probesSent = statistics.probesSent
            let responsesReceived = statistics.responsesReceived
            let timeouts = statistics.timeouts
            let successRate =
                probesSent > 0 ? Double(responsesReceived) / Double(probesSent) * 100.0 : 0.0

            let avgLatency = statistics.averageLatency ?? 0.0
            let avgLatencyMs = (avgLatency * 1000.0).rounded(toPlaces: 1)

            self.statisticsLabel.text = String(
                format:
                    "Sent: %d, Received: %d, Timeouts: %d\nSuccess Rate: %.1f%%, Avg Latency: %.1fms",
                probesSent, responsesReceived, timeouts, successRate, avgLatencyMs
            )
        }
    }

    // MARK: - Actions

    @objc private func startStopButtonTapped() {
        if isRunning {
            stopTraceroute()
        } else {
            startTraceroute()
        }
    }

    @objc private func dismissKeyboard() {
        view.endEditing(true)
    }

    @objc private func ipVersionSwitchChanged(_ sender: UISwitch) {
        if sender == forceIPv4Switch && sender.isOn {
            forceIPv6Switch.setOn(false, animated: true)
        } else if sender == forceIPv6Switch && sender.isOn {
            forceIPv4Switch.setOn(false, animated: true)
        }
    }

    // MARK: - Traceroute Control

    private func startTraceroute() {
        guard let hostName = hostNameTextField.text, !hostName.isEmpty else {
            showAlert(title: "Error", message: "Please enter a hostname or IP address")
            return
        }

        guard let configuration = createConfiguration() else {
            return
        }

        // Clear previous results
        tracerouteResults.removeAll()
        tableView.reloadData()

        // Create and configure traceroute
        let traceroute = SwiftSimpleTraceroute(hostName: hostName, configuration: configuration)
        traceroute.delegate = self
        swiftTraceroute = traceroute

        // Set address style
        if forceIPv4Switch.isOn {
            traceroute.addressStyle = .icmPv4
        } else if forceIPv6Switch.isOn {
            traceroute.addressStyle = .icmPv6
        } else {
            traceroute.addressStyle = .any
        }

        do {
            try traceroute.start()
            isRunning = true
            progressLabel.text = "Starting traceroute to \(hostName)..."
            NSLog("Traceroute started to %@", hostName)
        } catch {
            showAlert(title: "Failed to Start", message: error.localizedDescription)
            swiftTraceroute = nil
        }
    }

    private func stopTraceroute() {
        swiftTraceroute?.stop()
        swiftTraceroute = nil
        isRunning = false
        progressLabel.text = "Traceroute stopped"
        NSLog("Traceroute stopped")
    }

    private func createConfiguration() -> STracerouteConfiguration? {
        var config = STracerouteConfiguration()

        // Validate and set max hops
        if let maxHopsText = maxHopsTextField.text, let maxHops = UInt8(maxHopsText) {
            guard maxHops >= 1 && maxHops <= 255 else {
                showAlert(title: "Invalid Max Hops", message: "Max hops must be between 1 and 255")
                return nil
            }
            config.maxHops = maxHops
        }

        // Validate and set timeout
        if let timeoutText = timeoutTextField.text, let timeout = TimeInterval(timeoutText) {
            guard timeout >= 0.1 && timeout <= 60.0 else {
                showAlert(
                    title: "Invalid Timeout",
                    message: "Timeout must be between 0.1 and 60.0 seconds")
                return nil
            }
            config.timeout = timeout
        }

        // Validate and set probes per hop
        if let probesText = probesPerHopTextField.text, let probes = UInt8(probesText) {
            guard probes >= 1 && probes <= 10 else {
                showAlert(
                    title: "Invalid Probes Per Hop",
                    message: "Probes per hop must be between 1 and 10")
                return nil
            }
            config.probesPerHop = probes
        }

        return config
    }

    private func showAlert(title: String, message: String) {
        DispatchQueue.main.async {
            let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            self.present(alert, animated: true)
        }
    }
}

// MARK: - UITextFieldDelegate

extension TracerouteViewController: UITextFieldDelegate {
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
        return true
    }
}

// MARK: - SwiftSimpleTracerouteDelegate

// MARK: - SwiftSimpleTracerouteDelegate

extension TracerouteViewController: SwiftSimpleTracerouteDelegate {

    nonisolated func swiftSimpleTraceroute(
        _ traceroute: SwiftSimpleTraceroute, didStartWithAddress address: String
    ) {
        Task { @MainActor in
            self.progressLabel.text = "Traceroute started to \(address)"
            NSLog("Traceroute started to %@", address)
        }
    }

    nonisolated func swiftSimpleTraceroute(
        _ traceroute: SwiftSimpleTraceroute, didFailWithError error: STracerouteError
    ) {
        Task { @MainActor in
            let errorString = error.localizedDescription
            self.progressLabel.text = "Traceroute failed: \(errorString)"
            NSLog("Traceroute failed: %@", errorString)
            self.stopTraceroute()
            self.showAlert(title: "Traceroute Failed", message: errorString)
        }
    }

    nonisolated func swiftSimpleTraceroute(
        _ traceroute: SwiftSimpleTraceroute, didCompleteHop hop: STracerouteHop
    ) {
        let maxHops = traceroute.maxHops
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            // Add or update hop result
            if let existingIndex = self.tracerouteResults.firstIndex(where: {
                $0.hopNumber == hop.hopNumber
            }) {
                self.tracerouteResults[existingIndex] = hop
            } else {
                self.tracerouteResults.append(hop)
                self.tracerouteResults.sort { $0.hopNumber < $1.hopNumber }
            }

            // Update table view
            self.tableView.reloadData()

            // Update progress
            self.updateProgress(currentHop: hop.hopNumber, maxHops: maxHops)

            // Log result
            if hop.isTimeout {
                NSLog("Hop %d: * * * (timeout)", hop.hopNumber)
            } else if let roundTripTime = hop.roundTripTime {
                let latencyMs = (roundTripTime * 1000.0).rounded(toPlaces: 1)
                NSLog(
                    "Hop %d: %@ (%.1fms)", hop.hopNumber, hop.routerAddress ?? "unknown", latencyMs)
            }
        }
    }

    nonisolated func swiftSimpleTraceroute(
        _ traceroute: SwiftSimpleTraceroute, didUpdateStatistics statistics: STracerouteStatistics
    ) {
        Task { @MainActor in
            updateStatistics(statistics)
        }
    }

    nonisolated func swiftSimpleTraceroute(
        _ traceroute: SwiftSimpleTraceroute, didFinishWithResult result: STracerouteResult
    ) {
        Task { @MainActor in
            self.isRunning = false

            let totalTime = result.totalTime.rounded(toPlaces: 2)
            let reachedTarget = result.reachedTarget ? "reached" : "did not reach"

            self.progressLabel.text =
                "Traceroute completed: \(reachedTarget) target in \(totalTime)s"

            NSLog("Traceroute completed: %@ target in %.2fs", reachedTarget, totalTime)
            NSLog("Total hops: %d, Target: %@", result.actualHops, result.targetHostname)
        }
    }
}

// MARK: - UITableViewDataSource & UITableViewDelegate

extension TracerouteViewController: UITableViewDataSource, UITableViewDelegate {

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return tracerouteResults.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell =
            tableView.dequeueReusableCell(withIdentifier: "TracerouteHopCell", for: indexPath)
            as! TracerouteHopCell

        let hop = tracerouteResults[indexPath.row]
        cell.configure(with: hop)

        return cell
    }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        return tracerouteResults.isEmpty ? nil : "Traceroute Hops"
    }
}
