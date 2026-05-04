import Foundation

struct VPNService {
    let preferredEthernetInterface: String?
    let macAddress: String
    let xboxAddress: String

    init(
        preferredEthernetInterface: String? = nil,
        macAddress: String = "10.0.0.1",
        xboxAddress: String = "10.0.0.2"
    ) {
        self.preferredEthernetInterface = preferredEthernetInterface
        self.macAddress = macAddress
        self.xboxAddress = xboxAddress
    }

    func resolveConfiguration() throws -> ResolvedConfig {
        let ifconfigAll = try CommandRunner.run("/sbin/ifconfig", ["-a"]).output
        let hardwarePortsText = (try? CommandRunner.run("/usr/sbin/networksetup", ["-listallhardwareports"]).output) ?? ""

        let interfaceStates = mergedInterfaceStates(from: ifconfigAll)
        let hardwarePorts = parseHardwarePorts(from: hardwarePortsText)
        let vpnMatch = detectVPN(in: ifconfigAll)

        let ethernetState = chooseEthernetInterface(
            from: interfaceStates,
            hardwarePorts: hardwarePorts
        )

        return ResolvedConfig(
            ethernetInterface: ethernetState?.name ?? preferredEthernetInterface ?? "en5",
            ethernetLabel: ethernetState.map { hardwarePorts[$0.name] ?? $0.name } ?? (preferredEthernetInterface ?? "Ethernet"),
            macAddress: macAddress,
            xboxAddress: xboxAddress,
            detectedVPNInterface: vpnMatch?.name,
            detectedVPNAddress: vpnMatch?.ipv4
        )
    }

    func collectSnapshot() throws -> AppSnapshot {
        let resolved = try resolveConfiguration()

        var snapshot = AppSnapshot()
        snapshot.resolvedConfig = resolved
        snapshot.detectedVPNInterface = resolved.detectedVPNInterface
        snapshot.detectedVPNAddress = resolved.detectedVPNAddress

        let ifconfigAll = try CommandRunner.run("/sbin/ifconfig", ["-a"]).output
        let routes = try CommandRunner.run("/usr/sbin/netstat", ["-rn", "-f", "inet"]).output
        let forwarding = try CommandRunner.run("/usr/sbin/sysctl", ["net.inet.ip.forwarding"]).output
        let caffeinate = try CommandRunner.run("/usr/bin/pgrep", ["-af", "caffeinate"])
        let arp = try? CommandRunner.run("/usr/sbin/arp", ["-an"]).output
        let pfCheck = try? CommandRunner.run("/usr/bin/sudo", ["-n", "/sbin/pfctl", "-a", "com.apple/xboxvpn", "-s", "nat"]).output

        let interfaceStates = mergedInterfaceStates(from: ifconfigAll)
        let ethernetState = interfaceStates.first { $0.name == resolved.ethernetInterface }

        snapshot.ethernetIsActive = ethernetState?.isActive ?? false
        snapshot.ethernetHasExpectedIP = ethernetState?.ipv4Addresses.contains(resolved.macAddress) ?? false
        snapshot.staleIPInterfaces = interfaceStates
            .filter { $0.name != resolved.ethernetInterface && $0.ipv4Addresses.contains(resolved.macAddress) }
            .map(\.name)
        snapshot.xboxVisibleOnLAN = hasRoute(to: resolved.xboxAddress, routes: routes) || hasARPEntry(for: resolved.xboxAddress, arpText: arp)
        snapshot.ipForwardingEnabled = forwarding.contains(": 1")
        snapshot.caffeinateRunning = caffeinate.status == 0 && !caffeinate.output.isEmpty

        if let pfCheck, !pfCheck.isEmpty {
            snapshot.pfAnchorStatus = pfCheck
        }

        snapshot.items = [
            StatusItem(
                title: "Wi-Fi и аплинк",
                detail: routes.contains("default") ? "Базовый IPv4-маршрут присутствует." : "Не вижу default route.",
                level: routes.contains("default") ? .ok : .error
            ),
            StatusItem(
                title: "VPN-интерфейс",
                detail: resolved.detectedVPNInterface == nil ? "Активный utun с IPv4 не найден." : "\(resolved.detectedVPNInterface!) -> \(resolved.detectedVPNAddress ?? "без IPv4")",
                level: resolved.detectedVPNInterface == nil ? .error : .ok
            ),
            StatusItem(
                title: "Ethernet для Xbox",
                detail: snapshot.ethernetIsActive
                    ? "\(resolved.ethernetInterface) (\(resolved.ethernetLabel)) активен."
                    : "\(resolved.ethernetInterface) найден, но линк сейчас не поднят, либо адаптер переподключился под другим именем.",
                level: snapshot.ethernetIsActive ? .ok : .error
            ),
            StatusItem(
                title: "IP на Mac",
                detail: snapshot.ethernetHasExpectedIP ? "\(resolved.macAddress) уже назначен." : "Ожидаемый IP \(resolved.macAddress) не найден на \(resolved.ethernetInterface).",
                level: snapshot.ethernetHasExpectedIP ? .ok : .warning
            ),
            StatusItem(
                title: "Конфликт IP на интерфейсах",
                detail: snapshot.staleIPInterfaces.isEmpty
                    ? "Повторяющийся \(resolved.macAddress) на других интерфейсах не найден."
                    : "\(resolved.macAddress) ещё висит на: \(snapshot.staleIPInterfaces.joined(separator: ", ")). Это может ломать маршрут до Xbox.",
                level: snapshot.staleIPInterfaces.isEmpty ? .ok : .warning
            ),
            StatusItem(
                title: "Видимость Xbox",
                detail: snapshot.xboxVisibleOnLAN ? "Xbox выглядит достижимым на \(resolved.xboxAddress)." : "Xbox пока не виден на \(resolved.xboxAddress).",
                level: snapshot.xboxVisibleOnLAN ? .ok : .warning
            ),
            StatusItem(
                title: "IP-форвардинг",
                detail: snapshot.ipForwardingEnabled ? "Включен." : "Выключен.",
                level: snapshot.ipForwardingEnabled ? .ok : .error
            ),
            StatusItem(
                title: "Защита от сна",
                detail: snapshot.caffeinateRunning ? "caffeinate уже запущен." : "caffeinate не найден.",
                level: snapshot.caffeinateRunning ? .ok : .warning
            ),
            StatusItem(
                title: "PF anchor",
                detail: snapshot.pfAnchorStatus,
                level: snapshot.pfAnchorStatus.contains("Permission denied") || snapshot.pfAnchorStatus.contains("password") ? .unknown : .ok
            )
        ]

        return snapshot
    }

    func buildStartScript(for config: ResolvedConfig) -> String {
        """
        #!/bin/bash
        set -euo pipefail

        PREFERRED_ETH_IF="\(config.ethernetInterface)"
        MAC_IP="\(config.macAddress)"
        XBOX_IP="\(config.xboxAddress)"
        SUBNET_MASK="255.255.255.0"
        SOURCE_CIDR="10.0.0.0/24"
        ANCHOR_NAME="com.apple/xboxvpn"
        PF_RULES_FILE="/tmp/games.vyatkino.xboxvpn.pf.conf"

        detect_ethernet_if() {
          if /sbin/ifconfig "$PREFERRED_ETH_IF" >/dev/null 2>&1; then
            echo "$PREFERRED_ETH_IF"
            return
          fi

          /usr/sbin/networksetup -listallhardwareports | /usr/bin/awk '
            /Hardware Port: .*LAN|Hardware Port: .*Ethernet/ { want=1; next }
            want && /^Device: / { print $2; exit }
            /^$/ { want=0 }
          '
        }

        ETH_IF="$(detect_ethernet_if)"
        if [[ -z "${ETH_IF:-}" ]]; then
          echo "Не удалось автоматически определить Ethernet-интерфейс для Xbox."
          exit 1
        fi

        cleanup_stale_ip_interfaces() {
          /sbin/ifconfig -a | /usr/bin/awk -v target_ip="$MAC_IP" '
            /^[^[:space:]].*: flags=/ {
              iface=$1
              sub(":", "", iface)
            }
            $1 == "inet" && $2 == target_ip {
              print iface
            }
          ' | while read -r iface; do
            if [[ -n "${iface:-}" && "$iface" != "$ETH_IF" ]]; then
              echo "Убираю $MAC_IP с лишнего интерфейса $iface..."
              /sbin/ifconfig "$iface" inet delete "$MAC_IP" || true
            fi
          done
        }

        VPN_IF=$(/sbin/ifconfig -a | /usr/bin/awk '
        /^utun[0-9]+:/ { iface=$1; sub(":", "", iface) }
        /inet / && iface ~ /^utun/ && $2 !~ /^127\\./ { print iface; exit }
        ')

        if [[ -z "${VPN_IF:-}" ]]; then
          echo "Не найден активный VPN-интерфейс utunX с IPv4."
          exit 1
        fi

        /usr/bin/nohup /usr/bin/caffeinate -disu >/tmp/xboxvpnhelper-caffeinate.log 2>&1 &
        /usr/bin/sudo -n true >/dev/null 2>&1 || true
        /usr/bin/printf "Настраиваю энергосбережение...\\n"
        /usr/bin/pmset -a autopoweroff 0
        /usr/bin/pmset -a powernap 0
        /usr/bin/pmset -a standby 0
        /usr/bin/pmset -a proximitywake 0
        /usr/bin/pmset -a tcpkeepalive 1

        /usr/bin/printf "Сбрасываю pf и включаю форвардинг...\\n"
        /sbin/pfctl -d || true
        /sbin/pfctl -F all
        /usr/sbin/sysctl -w net.inet.ip.forwarding=1

        cleanup_stale_ip_interfaces
        /usr/bin/printf "Назначаю %s на %s...\\n" "$MAC_IP" "$ETH_IF"
        /sbin/ifconfig "$ETH_IF" "$MAC_IP" netmask "$SUBNET_MASK" up

        /usr/bin/printf "Перестраиваю NAT на %s с сохранением Xbox UDP-портов...\\n" "$VPN_IF"
        /sbin/pfctl -F nat
        if ! /usr/bin/pgrep -x caffeinate >/dev/null 2>&1; then
          /usr/bin/nohup /usr/bin/caffeinate -disu >/tmp/xboxvpnhelper-caffeinate.log 2>&1 &
        fi

        /bin/cat >"$PF_RULES_FILE" <<EOF
        nat on $VPN_IF from $SOURCE_CIDR to any -> ($VPN_IF) static-port
        pass in on $ETH_IF
        pass out on $ETH_IF
        EOF

        /bin/cat "$PF_RULES_FILE" | /sbin/pfctl -Ef -
        /sbin/pfctl -k "$XBOX_IP" >/dev/null 2>&1 || true
        /usr/sbin/arp -d "$XBOX_IP" >/dev/null 2>&1 || true
        /usr/bin/printf "Текущее NAT-правило:\\n"
        /sbin/pfctl -s nat

        echo
        echo "Готово."
        echo "Mac: $ETH_IF -> $MAC_IP"
        echo "VPN: $VPN_IF"
        echo "Xbox: $XBOX_IP"
        echo "Если на Xbox всё уже выставлено, теперь можно перезагрузить Xbox и потом снова проверить статус."
        """
    }

    func buildReconnectScript(for config: ResolvedConfig) -> String {
        buildStartScript(for: config)
    }

    private func chooseEthernetInterface(
        from interfaces: [InterfaceState],
        hardwarePorts: [String: String]
    ) -> InterfaceState? {
        let ethernetCandidates = interfaces.filter { $0.name.hasPrefix("en") && $0.name != "en0" && $0.hasEthernet }

        if let preferredEthernetInterface,
           let preferred = ethernetCandidates.first(where: { $0.name == preferredEthernetInterface }) {
            return preferred
        }

        return ethernetCandidates.max { lhs, rhs in
            score(for: lhs, hardwarePorts: hardwarePorts) < score(for: rhs, hardwarePorts: hardwarePorts)
        }
    }

    private func score(for interface: InterfaceState, hardwarePorts: [String: String]) -> Int {
        let label = (hardwarePorts[interface.name] ?? "").lowercased()
        var score = 0

        if interface.ipv4Addresses.contains(macAddress) {
            score += 200
        }
        if interface.ipv4Addresses.contains(where: { $0.hasPrefix("169.254.") }) {
            score += 80
        }
        if interface.isActive {
            score += 70
        }
        if label.contains("sznx") {
            score += 60
        }
        if label.contains("usb") {
            score += 40
        }
        if label.contains("ethernet") || label.contains("lan") {
            score += 30
        }
        if interface.name == preferredEthernetInterface {
            score += 20
        }

        return score
    }

    private func parseHardwarePorts(from text: String) -> [String: String] {
        var result: [String: String] = [:]
        var currentPort: String?

        for line in text.components(separatedBy: .newlines) {
            if line.hasPrefix("Hardware Port: ") {
                currentPort = String(line.dropFirst("Hardware Port: ".count))
            } else if line.hasPrefix("Device: "), let currentPort {
                let device = String(line.dropFirst("Device: ".count))
                result[device] = currentPort
            }
        }

        return result
    }

    private func hasRoute(to ipAddress: String, routes: String) -> Bool {
        routes
            .components(separatedBy: .newlines)
            .contains { line in
                let parts = line.split(whereSeparator: \.isWhitespace)
                return parts.first.map(String.init) == ipAddress
            }
    }

    private func hasARPEntry(for ipAddress: String, arpText: String?) -> Bool {
        guard let arpText else {
            return false
        }

        return arpText
            .components(separatedBy: .newlines)
            .contains { $0.contains("(\(ipAddress))") }
    }

    private func parseInterfaces(from text: String) -> [InterfaceState] {
        let lines = text.components(separatedBy: .newlines)
        var groups: [[String]] = []
        var current: [String] = []

        for line in lines {
            if isInterfaceHeader(line) {
                if !current.isEmpty {
                    groups.append(current)
                }
                current = [line]
            } else if !current.isEmpty {
                current.append(line)
            }
        }

        if !current.isEmpty {
            groups.append(current)
        }

        return groups.compactMap { lines in
            guard let header = lines.first else {
                return nil
            }

            let name = header.split(separator: ":").first.map(String.init) ?? ""
            guard !name.isEmpty else {
                return nil
            }

            let ipv4s = lines.compactMap { line -> String? in
                let parts = line.split(whereSeparator: \.isWhitespace)
                guard parts.count >= 2, parts[0] == "inet" else {
                    return nil
                }
                return String(parts[1])
            }

            let isActive = lines.contains(where: { $0.contains("status: active") })
            let hasEthernet = lines.contains(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("ether ") })

            return InterfaceState(
                name: name,
                isActive: isActive,
                hasEthernet: hasEthernet,
                ipv4Addresses: ipv4s
            )
        }
    }

    private func mergedInterfaceStates(from ifconfigAll: String) -> [InterfaceState] {
        var interfaces = parseInterfaces(from: ifconfigAll)

        if let preferredEthernetInterface,
           interfaces.contains(where: { $0.name == preferredEthernetInterface }) == false,
           let directText = try? CommandRunner.run("/sbin/ifconfig", [preferredEthernetInterface]).output,
           let directState = parseInterfaces(from: directText).first {
            interfaces.append(directState)
        }

        return interfaces
    }

    private func detectVPN(in text: String) -> (name: String, ipv4: String)? {
        for iface in parseInterfaces(from: text) {
            guard iface.name.hasPrefix("utun") else {
                continue
            }
            if let ipv4 = iface.ipv4Addresses.first {
                return (iface.name, ipv4)
            }
        }

        return nil
    }

    private func isInterfaceHeader(_ line: String) -> Bool {
        guard let first = line.first, !first.isWhitespace else {
            return false
        }
        return line.contains(": flags=")
    }
}

private struct InterfaceState {
    let name: String
    let isActive: Bool
    let hasEthernet: Bool
    let ipv4Addresses: [String]
}
