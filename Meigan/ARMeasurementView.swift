import SwiftUI

struct ARMeasurementView: View {
    @AppStorage("hasSeenExplainer") private var hasSeenExplainer = false
    @State private var showExplainer = false

    var body: some View {
        Group{
            if showExplainer {
                ExplainerView(
                onStart: {
                    hasSeenExplainer = true
                    showExplainer = false
                }
                )
            } else {
                ZStack {
                    ARSceneView() // from another file
                    OverlaysView() // (crosshair, buttons, etc.)
                }
            }
        }
        .onAppear {
        if !hasSeenExplainer {
            showExplainer = true
        }
    }
    }
}

// View for the explainer screen
private struct ExplainerView: View {
    let onStart: () -> Void // Called when user taps "Start Measuring"
    var body: some View {
        ZStack{
            // Dimmed background
            Color.black.opacity(0.4)
                .ignoresSafeArea()
            
            // Centered content
            VStack(spacing: 16){
                Image("Logo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 72, height: 72)

                Text("Camera access needed")
                    .font(.title2)
                    .fontWeight(.semibold)

                Text("Meigan uses your camera to measure distances in 3D space. iOS will ask for permission the first time you start measuring.")
                    .font(.subheadline)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)

                Button {
                    onStart()
                } label: {
                    Text("Start AR Measurement")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(24)
            .background(.thinMaterial)
            .cornerRadius(20)
            .padding(.horizontal, 24)
        }
    }
}

// View for crosshair, buttons, etc.
private struct OverlaysView: View {
    var body: some View {
        ZStack {
            // Center crosshair
            Circle()
                .strokeBorder(Color.white.opacity(0.85), lineWidth: 2)
                .frame(width: 32, height: 32)

            VStack {
                // Top status / hint
                Text("Aim at first point")
                    .font(.subheadline)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.thinMaterial)
                    .overlay(
                        Capsule()
                            .fill(Color.black.opacity(0.25))
                    )
                    .clipShape(Capsule())
                    .padding(.top, 16)

                Spacer()

                // Bottom measurement + controls
                VStack(spacing: 12) {
                    // Distance readout (placeholder for now)
                    Text("—")
                        .font(.title)
                        .fontWeight(.semibold)

                    HStack(spacing: 12) {
                        Button("Place Point") {
                            // TODO: hook into measurement flow
                        }
                        .buttonStyle(.borderedProminent)

                        Button("Clear") {
                            // TODO: hook into measurement reset
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .padding()
                .background(.thinMaterial)
                .cornerRadius(20)
                .padding(.horizontal)
                .padding(.bottom, 16)
            }
        }
        .foregroundColor(.white)
    }
}

#Preview {
    NavigationStack {
        ARMeasurementView()
    }
}