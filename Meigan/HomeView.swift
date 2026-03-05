//
//  HomeView.swift
//  Meigan
//
//  Created by Ryan Chen on 2026-02-19.
//

import SwiftUI

struct HomeView: View {
    var body: some View {
        GeometryReader { geometry in
            let logoSize = geometry.size.height / 4

            ScrollView {
                VStack(spacing: 32) {
                    // Header - Logo, name, tagline
                    VStack(spacing: 12) {
                        Image("Logo")
                            .resizable()
                            .scaledToFit()
                            .frame(width: logoSize, height: logoSize)

                        Text("Meigan")
                            .font(.largeTitle)
                            .fontWeight(.bold)

                        Text("Precision 3D measurement")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    // Primary CTA
                    NavigationLink {
                        ARMeasurementView() 
                    } label: {
                        Text("Start Measuring")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .padding(.horizontal, 24)

                    // Secondary actions
                    VStack(spacing: 12) {
                        Button {
                            // TODO: Show how it works
                        } label: {
                            HStack {
                                Image(systemName: "questionmark.circle")
                                Text("How it works")
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                        }
                        .buttonStyle(.bordered)

                        NavigationLink {
                            SettingsView()
                        } label: {
                            HStack {
                                Image(systemName: "gearshape")
                                Text("Settings")
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding(.horizontal, 24)
                }
                .padding(.vertical, 24)
            }
            .scrollIndicators(.hidden)
        }
    }
}

#Preview {
    HomeView()
}
