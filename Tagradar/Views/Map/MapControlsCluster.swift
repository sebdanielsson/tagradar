import CoreLocation
import MapKit
import SwiftUI

/// Bottom-right map controls on iPhone, Apple Maps style: map type and user location.
struct MapControlsCluster: View {
    @Binding var camera: MapCameraPosition
    @Environment(AppSettings.self) private var settings
    @Environment(LocationManager.self) private var location
    @Environment(\.openURL) private var openURL
    @State private var showDeniedAlert = false
    @State private var isLocating = false

    var body: some View {
        @Bindable var settings = settings
        GlassEffectContainer(spacing: 0) {
            VStack(spacing: 0) {
                Menu {
                    Picker("Map type", selection: $settings.mapAppearance) {
                        Label("Standard", systemImage: "map").tag(AppSettings.MapAppearance.standard)
                        Label("Muted", systemImage: "map.fill").tag(AppSettings.MapAppearance.muted)
                        Label("Satellite", systemImage: "globe.europe.africa.fill").tag(AppSettings.MapAppearance.hybrid)
                    }
                    Divider()
                    Toggle("Show train numbers", isOn: $settings.showTrainLabels)
                    Toggle("Colour trains by delay", isOn: $settings.colorMarkersByDelay)
                    Toggle("Show stations", isOn: $settings.showStations)
                } label: {
                    Image(systemName: "map")
                        .font(.body.weight(.medium))
                        .frame(width: 44, height: 44)
                        .contentShape(.rect)
                }
                .accessibilityLabel(Text("Map type"))
                Divider().frame(width: 28)
                Button {
                    locate()
                } label: {
                    Image(systemName: isLocating ? "location.fill" : "location")
                        .font(.body.weight(.medium))
                        .frame(width: 44, height: 44)
                        .contentShape(.rect)
                }
                .accessibilityLabel(Text("My location"))
            }
            .glassEffect(.regular.interactive(), in: .rect(corners: .concentric(minimum: 14), isUniform: true))
        }
        .onChange(of: location.status) { _, _ in
            if location.pendingCenter, location.isAuthorized {
                location.pendingCenter = false
                follow()
            }
        }
        .alert("Location access is off", isPresented: $showDeniedAlert) {
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    openURL(url)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Allow location access for Tågradar in Settings to center the map on you.")
        }
    }

    private func locate() {
        if location.isAuthorized {
            follow()
        } else if location.isDenied {
            showDeniedAlert = true
        } else {
            location.pendingCenter = true
            location.requestAccess()
        }
    }

    /// Centers on the user with a span that shows nearby trains, not a single street.
    private func follow() {
        guard !isLocating else { return }
        isLocating = true
        Task {
            defer { isLocating = false }
            guard let fix = await location.currentLocation() else { return }
            withAnimation(.smooth) {
                camera = .region(MKCoordinateRegion(
                    center: fix.coordinate,
                    span: MKCoordinateSpan(latitudeDelta: 0.35, longitudeDelta: 0.35)
                ))
            }
        }
    }
}
