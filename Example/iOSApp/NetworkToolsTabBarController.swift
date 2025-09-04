/*
    Abstract:
    A tab bar controller for the Network Tools demo app.
 */

import UIKit

class NetworkToolsTabBarController: UITabBarController {

    override func viewDidLoad() {
        super.viewDidLoad()
        setupTabs()
        setupAppearance()
    }

    private func setupTabs() {
        // Create Ping tab
        let pingViewController = PingViewController()
        let pingNavController = UINavigationController(rootViewController: pingViewController)
        pingNavController.tabBarItem = UITabBarItem(
            title: "Ping",
            image: UIImage(systemName: "dot.radiowaves.left.and.right"),
            tag: 0
        )

        // Create Traceroute tab
        let tracerouteViewController = TracerouteViewController()
        let tracerouteNavController = UINavigationController(
            rootViewController: tracerouteViewController)
        tracerouteNavController.tabBarItem = UITabBarItem(
            title: "Traceroute",
            image: UIImage(systemName: "map"),
            tag: 1
        )

        // Set view controllers
        viewControllers = [pingNavController, tracerouteNavController]

        // Set default selection
        selectedIndex = 0
    }

    private func setupAppearance() {
        // Configure tab bar appearance
        tabBar.tintColor = .systemBlue
        tabBar.unselectedItemTintColor = .systemGray
        tabBar.backgroundColor = .systemBackground

        // Configure navigation appearance
        let appearance = UINavigationBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = .systemBackground
        appearance.titleTextAttributes = [.foregroundColor: UIColor.label]
        appearance.largeTitleTextAttributes = [.foregroundColor: UIColor.label]

        UINavigationBar.appearance().standardAppearance = appearance
        UINavigationBar.appearance().compactAppearance = appearance
        UINavigationBar.appearance().scrollEdgeAppearance = appearance
    }
}
