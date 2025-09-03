//
//  Double+round.swift
//  MacTool
//
//  Created by MTC.DEV.JIANG on 2025/9/2.
//

import Foundation

// MARK: - Double Extension for Rounding
extension Double {
    func rounded(toPlaces places: Int) -> Double {
        let divisor = pow(10.0, Double(places))
        return (self * divisor).rounded() / divisor
    }
}
