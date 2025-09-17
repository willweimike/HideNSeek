import SwiftUI

struct ContentView: View {
    @Environment(\.presentationMode) var presentationMode
    @State private var isHideAndSeekEnabled: Bool = {
        if UserDefaults.standard.object(forKey: "HideAndSeekEnabled") == nil {
            UserDefaults.standard.set(true, forKey: "HideAndSeekEnabled") // Set default value
            return true
        }
        return UserDefaults.standard.bool(forKey: "HideAndSeekEnabled")
    }()
    
    var body: some View {
        VStack(spacing: 2) {
            Toggle("Enable HideNSeek", isOn: $isHideAndSeekEnabled)
                .padding()
                .onChange(of: isHideAndSeekEnabled) { newValue in
                    UserDefaults.standard.set(newValue, forKey: "HideAndSeekEnabled")
                    NotificationCenter.default.post(name: NSNotification.Name("HideAndSeekStateChanged"), object: newValue)
                }

            Text("Please ensure that accessibility and automation permissions are enabled.")
                    .font(.footnote)
                    .padding(15)
                    .foregroundColor(.orange)
                    .multilineTextAlignment(.center)
        }
        .frame(width: 210, height: 150)

    }
}
