import Foundation
import Security
import SwiftUI

private enum CredentialStore {
    private static var key: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: Bundle.main.bundleIdentifier ?? "top.mcdkf.dzz.workbench",
         kSecAttrAccount as String: "workbench-login"]
    }

    static func read() -> Credentials? {
        var query = key
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(Credentials.self, from: data)
    }

    static func save(_ credentials: Credentials) throws {
        let encoded = try JSONEncoder().encode(credentials)
        let value = [kSecValueData as String: encoded]
        let updated = SecItemUpdate(key as CFDictionary, value as CFDictionary)
        if updated == errSecSuccess { return }
        guard updated == errSecItemNotFound else { throw SecretError.unavailable }
        var entry = key
        entry[kSecValueData as String] = encoded
        entry[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        guard SecItemAdd(entry as CFDictionary, nil) == errSecSuccess else { throw SecretError.unavailable }
    }

    static func remove() throws {
        let status = SecItemDelete(key as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw SecretError.unavailable }
    }

    private enum SecretError: LocalizedError {
        case unavailable
        var errorDescription: String? { "无法访问 iPhone 钥匙串，请解锁设备后再试。" }
    }
}

@MainActor
final class SessionStore: ObservableObject {
    @Published private(set) var api: WorkbenchAPI?
    @Published private(set) var username = ""
    @Published private(set) var refreshVersion = 0
    @Published private(set) var loading = false
    @Published var message: String?
    @Published var pushMessage: String?
    private var didRestore = false
    private var pushRegistration: Task<Void, Error>?
    private var pushRegistrationID: UUID?
    private var disablingPush = false

    let installationID: UUID = {
        let defaults = UserDefaults.standard
        let key = "workbench.installationID"
        if let value = defaults.string(forKey: key), let id = UUID(uuidString: value) { return id }
        let id = UUID()
        defaults.set(id.uuidString, forKey: key)
        return id
    }()

    func restore() async {
        guard !didRestore else { return }
        didRestore = true
        guard let credentials = CredentialStore.read() else { return }
        await authenticate(credentials, persist: false)
    }

    func signIn(username: String, password: String) async {
        await authenticate(Credentials(username: username.trimmingCharacters(in: .whitespacesAndNewlines),
                                       password: password), persist: true)
    }

    private func authenticate(_ credentials: Credentials, persist: Bool) async {
        guard !loading else { return }
        loading = true
        message = nil
        defer { loading = false }
        do {
            let client = WorkbenchAPI(credentials: credentials)
            let name = try await client.signIn()
            if persist { try CredentialStore.save(credentials) }
            username = name
            api = client
        } catch {
            if (error as? APIError)?.unauthorized == true { try? CredentialStore.remove() }
            message = error.localizedDescription
        }
    }

    func signOut() async {
        guard let api, !loading else { return }
        loading = true
        defer { loading = false }
        do {
            if let pushRegistration { _ = await pushRegistration.result }
            do { try await api.unregisterDevice(installationID) }
            catch where (error as? APIError)?.unauthorized == true { }
            try CredentialStore.remove()
            self.api = nil
            username = ""
            message = nil
            pushMessage = nil
        } catch { message = error.localizedDescription }
    }

    func changed() { refreshVersion &+= 1 }

    func syncPush(_ token: String, environment: String) async {
        guard let api, !loading, !disablingPush else { return }
        let previous = pushRegistration
        let registrationID = UUID()
        let deviceID = installationID
        let operation = Task {
            if let previous { _ = await previous.result }
            try await api.registerDevice(deviceID, token: token, environment: environment)
        }
        pushRegistration = operation
        pushRegistrationID = registrationID
        defer {
            if pushRegistrationID == registrationID { pushRegistration = nil; pushRegistrationID = nil }
        }
        do {
            try await operation.value
            if pushRegistrationID == registrationID { pushMessage = "本机已注册提醒" }
        } catch {
            if pushRegistrationID == registrationID { pushMessage = "推送注册失败：\(error.localizedDescription)" }
        }
    }

    func disablePush() async -> Bool {
        guard let api, !loading, !disablingPush else { return false }
        disablingPush = true
        defer { disablingPush = false }
        do {
            if let pushRegistration { _ = await pushRegistration.result }
            try await api.unregisterDevice(installationID)
            pushMessage = "本机提醒已关闭"
            return true
        } catch {
            pushMessage = error.localizedDescription
            return false
        }
    }
}

@MainActor
struct SignInView: View {
    @EnvironmentObject private var session: SessionStore
    @State private var username = ""
    @State private var password = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label("个人工作台", systemImage: "square.grid.2x2.fill")
                        .font(.largeTitle.bold())
                        .foregroundStyle(.tint)
                        .padding(.vertical, 12)
                }
                Section("工作台账号") {
                    TextField("用户名", text: $username)
                        .textContentType(.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("密码", text: $password)
                        .textContentType(.password)
                        .onSubmit(signIn)
                    if let message = session.message { Text(message).foregroundStyle(.red) }
                    Button(action: signIn) {
                        if session.loading { ProgressView() } else { Text("登录").fontWeight(.semibold) }
                    }
                    .disabled(session.loading || username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || password.isEmpty)
                } footer: {
                    Text("通过 HTTPS 连接 dzz.mcdkf.top:7736。登录凭据保存在本机钥匙串。")
                }
            }
        }
    }

    private func signIn() {
        guard !session.loading, !username.isEmpty, !password.isEmpty else { return }
        Task { await session.signIn(username: username, password: password) }
    }
}
