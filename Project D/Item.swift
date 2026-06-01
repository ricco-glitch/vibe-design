//
//  Item.swift
//  Project D
//
//  Created by Fang on 2026/6/1.
//

import Foundation
import SwiftData

@Model
final class Item {
    var timestamp: Date
    
    init(timestamp: Date) {
        self.timestamp = timestamp
    }
}
