//
//  CameraAuthorizationService.swift
//  Meigan
//
//  Camera permission status and requests for AR measurement.
//

import AVFoundation
import UIKit

// MARK: - Gate phase

/// High-level UI state for entering AR measurement based on camera authorization.
enum CameraAccessGatePhase: Equatable {
    case prePrompt
    case requesting
    case denied
    case ready
}

enum CameraAccessGateResolver {
    static func resolve(status: AVAuthorizationStatus, isRequesting: Bool) -> CameraAccessGatePhase {
        if isRequesting { return .requesting }
        switch status {
        case .authorized:
            return .ready
        case .notDetermined:
            return .prePrompt
        case .denied, .restricted:
            return .denied
        @unknown default:
            return .denied
        }
    }
}

// MARK: - Authorization service

protocol CameraAuthorizing {
    var status: AVAuthorizationStatus { get }
    func requestAccess() async -> Bool
    func openAppSettings()
}

struct SystemCameraAuthorizationService: CameraAuthorizing {
    var status: AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .video)
    }

    func requestAccess() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .video)
    }

    func openAppSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}
