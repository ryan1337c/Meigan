<h1 align="center">
  <br>
  <a href="https://github.com/ryan1337c/Meigan">
    <img src="https://raw.githubusercontent.com/ryan1337c/Meigan/master/Meigan/Assets.xcassets/AppIcon.appiconset/MeiganIcon.png" alt="Meigan" width="200">
  </a>
  <br>
  <div>Meigan</div>
  <br>
</h1>

<h4 align="center">An iOS AR measurement app for measuring real-world distance, surfaces, and objects in 3D.</h4>

<p align="center">
  <a href="#key-features">Key Features</a> •
  <a href="#demo">Demo</a> •
  <a href="#installation">Installation</a> •
  <a href="#how-to-use">How To Use</a> •
  <a href="#credits">Credits</a> •
  <a href="#license">License</a>
</p>

## Key Features

* AR Distance Measurement
  - Place points in the real world and view distances with labels anchored in 3D space.
* Ruler Mode
  - Create connected measurement lines with live previews and snapping to existing endpoints and midpoints.
* Flatten Mode (Pro)
  - Mark four corners of a surface and transform it into a flattened, measurable image.
  - Within the flattened image, auto detect shapes and display their corresponding width, height, and perimenter. 
* Identify Mode (Pro)
  - Detect and label common objects in real time using an on-device Core ML model.
  - Powered by COCO 80 classification dataset, which was trained on yolo26n model. 
* Smart Placement Guidance
  - Receive visual guidance for low light, excessive movement, nearby surfaces, and AR tracking conditions.
* Save and Share
  - Preview captures, save them to Photos, or export them through the iOS share sheet.
* Metric and Imperial Units
  - Display measurements using your preferred unit system.
* LiDAR Support
  - Use scene reconstruction on compatible devices for improved surface understanding.
* AR Screenshots
  - Capture measurements and object-detection labels directly from the AR view.
* Haptic Feedback
  - Receive tactile confirmation when placing measurement points.

## Demo

### Ruler Mode
[![Ruler Mode Demo](https://github.com/user-attachments/assets/96ae2684-4aba-4663-b759-e47336cca17f)](https://youtube.com/shorts/xpC5-fFwBuM)

### Flatten Mode

[![Flatten Mode Demo](https://github.com/user-attachments/assets/0b5657e1-e52c-4a0d-9f0b-9f2153fa8f93)](https://youtube.com/shorts/BfeSxQi_fo0)

### Identify Mode
[![Identify Mode Demo](https://github.com/user-attachments/assets/205cdd90-3a0d-4c68-b878-4585d9ae29cd)](https://youtube.com/shorts/TXqokrcKDLo)

## Installation

### Requirements

- macOS with Xcode 26 or later
- iPhone or iPad running iOS 16.4 or later
- Apple Developer account for device signing
- A physical device with a camera  
  - AR measurement features cannot be fully tested in the simulator.

### Install from Source

1. Clone the repository:

   ```bash
   git clone https://github.com/ryan1337c/Meigan.git
   cd Meigan
   ```

2. Open the Xcode project:

   ```bash
   open Meigan.xcodeproj
   ```

3. Wait for Xcode to resolve the Swift Package Manager dependencies.

4. Select the **Meigan** target and open **Signing & Capabilities**.

5. Choose your Apple Developer **Team** and, if necessary, replace the bundle identifier with one registered to your account.

6. Connect your iPhone or iPad and select it as the run destination.

7. Press **Run** (`⌘R`) to build and install Meigan.

> The fastest way to try the app is to select **Continue as guest**. Ruler Mode does not require an account or subscription.

## How to Use

### Getting Started

1. Open Meigan and complete the introductory screens.
2. Sign in, create an account, or select **Continue as guest**.
3. Tap **Start Measuring**.
4. Allow camera access when prompted.
5. Move your device slowly until Meigan detects a surface.
6. Select a measurement mode from the toolbar.

### Ruler Mode

1. Aim the crosshair at the point where you want the measurement to begin.
2. Tap the **Add Point** button.
3. Move the crosshair to another location and add another point.
4. The distance appears between the points in 3D space.
5. Continue adding points to create a connected measurement path.
6. Use **Clear** to remove the current measurements.

Ruler Mode supports snapping to existing endpoints and segment midpoints for more precise placement.

### Flatten Mode (Pro)

1. Select **Flatten** from the mode toolbar.
2. Place four points around the corners of a flat surface.
3. Adjust a corner by targeting and selecting it again, if needed.
4. Tap **Start Scan** after all four corners are placed.
5. Meigan creates a flattened image of the selected surface.
6. Tap detected shapes to view their width, height, and perimeter.
7. Save the result to Photos or share it with another app.

### Identify Mode (Pro)

1. Select **Identify** from the mode toolbar.
2. Point the camera at an object.
3. Keep the device steady while Meigan analyzes the scene.
4. Detected objects appear with a name, confidence score, and bounding box.
5. Capture a screenshot to save or share the labeled result.

Object detection runs on the device using Core ML.

### Saving and Sharing

1. Tap the screenshot button while measuring.
2. Review the image in the preview.
3. Choose **Save** to add it to Photos or **Share** to open the iOS share sheet.
4. Photo-library permission is requested only when saving an image.

### Settings

Open **Settings** from the profile menu to:

- Switch between metric and imperial units
- Enable or disable haptic feedback
- Manage your profile and account
- View or manage your Meigan Pro subscription

## Optional Backend Setup

Meigan uses Supabase for authentication, cloud preferences, account deletion, and subscription synchronization.

If you are creating your own deployment, replace the Supabase URL and publishable key in:

```text
Meigan/Supabase.swift
```

Your Supabase project must provide:

- A `profile` table
- A `sync_user_subscription` database function
- A `validate-subscription` Edge Function
- A `delete-account` Edge Function

Backend migrations and Edge Function source files are not currently included in this repository.

## Credits

Meigan uses the following open-source packages:

- [Supabase Swift](https://github.com/supabase/supabase-swift) — authentication, cloud synchronization, and backend functions
- [Swift Crypto](https://github.com/apple/swift-crypto)
- [Swift ASN.1](https://github.com/apple/swift-asn1)
- [Swift HTTP Types](https://github.com/apple/swift-http-types)
- [Swift Clocks](https://github.com/pointfreeco/swift-clocks)
- [Swift Concurrency Extras](https://github.com/pointfreeco/swift-concurrency-extras)
- [XCTest Dynamic Overlay](https://github.com/pointfreeco/xctest-dynamic-overlay)

Meigan is built using Apple technologies including:

- [SwiftUI](https://developer.apple.com/xcode/swiftui/)
- [ARKit](https://developer.apple.com/augmented-reality/arkit/)
- [RealityKit](https://developer.apple.com/augmented-reality/realitykit/)
- [Core ML](https://developer.apple.com/machine-learning/core-ml/)
- [Vision](https://developer.apple.com/documentation/vision)
- [StoreKit](https://developer.apple.com/storekit/)

Special thanks to the developers and maintainers of these projects and technologies.

## You may also like...

- [Omni](https://github.com/ryan1337c/Omni) - A educational AI assistant web app


## License

MIT

---


