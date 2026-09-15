//
//  Log.swift
//  Speakin
//
//  Watch live with:  log stream --predicate 'subsystem == "com.bylivebetter.apps.Speakin"' --level info
//

import Foundation
import os

nonisolated enum Log {
    static let app = Logger(subsystem: "com.bylivebetter.apps.Speakin", category: "app")
    static let audio = Logger(subsystem: "com.bylivebetter.apps.Speakin", category: "audio")
    static let speech = Logger(subsystem: "com.bylivebetter.apps.Speakin", category: "speech")
    static let store = Logger(subsystem: "com.bylivebetter.apps.Speakin", category: "store")
}
