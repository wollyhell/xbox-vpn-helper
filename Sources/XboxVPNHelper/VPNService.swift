import Foundation

struct VPNService: Sendable {
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
        let pfCheck = try? CommandRunner.run("/usr/bin/sudo", ["-n", "/sbin/pfctl", "-s", "nat"]).output
        let guardCheck = try? CommandRunner.run("/bin/launchctl", ["print", "system/local.openclaw.xbox-vpn-guard"]).output

        let interfaceStates = mergedInterfaceStates(from: ifconfigAll)
        let ethernetState = interfaceStates.first { $0.name == resolved.ethernetInterface }

        snapshot.ethernetIsActive = ethernetState?.isActive ?? false
        snapshot.ethernetHasExpectedIP = ethernetState?.ipv4Addresses.contains(resolved.macAddress) ?? false
        snapshot.staleIPInterfaces = interfaceStates
            .filter { $0.name != resolved.ethernetInterface && $0.ipv4Addresses.contains(resolved.macAddress) }
            .map(\.name)
        snapshot.xboxVisibleOnLAN = hasRoute(to: resolved.xboxAddress, routes: routes) || hasARPEntry(for: resolved.xboxAddress, arpText: arp)
        snapshot.ipForwardingEnabled = forwarding.contains(": 1")
        snapshot.vpnMTUReady = vpnMTUReady(interface: resolved.detectedVPNInterface, ifconfigAll: ifconfigAll)
        snapshot.caffeinateRunning = caffeinate.status == 0 && !caffeinate.output.isEmpty
        snapshot.guardInstalled = guardCheck?.contains("/Library/LaunchDaemons/local.openclaw.xbox-vpn-guard.plist") ?? false
        snapshot.guardRunning = guardCheck?.contains("state = running") ?? false

        if let pfCheck, !pfCheck.isEmpty {
            snapshot.pfAnchorStatus = pfCheck
            snapshot.xboxLivePortForwardReady = pfCheck.contains("port = 3074 -> \(resolved.xboxAddress) port 3074")
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
                detail: snapshot.ethernetHasExpectedIP ? "\(resolved.macAddress) уже назначен." : "macOS сбросила \(resolved.ethernetInterface) в DHCP/self-assigned режим, поэтому Xbox теряет шлюз.",
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
                detail: snapshot.ipForwardingEnabled ? "Включен." : "Выключен. Без него Mac не пересылает пакеты Xbox в VPN.",
                level: snapshot.ipForwardingEnabled ? .ok : .error
            ),
            StatusItem(
                title: "Xbox 360 Live MTU",
                detail: snapshot.vpnMTUReady
                    ? "VPN MTU готов для крупных Xbox Live UDP-пакетов."
                    : "VPN MTU ниже 1380 или VPN ещё не найден. Для GTA IV/Xbox 360 Live приложение выставит 1380 при запуске.",
                level: snapshot.vpnMTUReady ? .ok : .warning
            ),
            StatusItem(
                title: "Xbox Live 3074",
                detail: snapshot.xboxLivePortForwardReady
                    ? "UDP/TCP 3074 перенаправлен на Xbox для Xbox 360 Live."
                    : "Не удалось подтвердить перенаправление 3074 без прав администратора, либо правило ещё не применено.",
                level: snapshot.xboxLivePortForwardReady ? .ok : .unknown
            ),
            StatusItem(
                title: "Автопочинка",
                detail: snapshot.guardRunning
                    ? "LaunchDaemon guard запущен и будет возвращать Ethernet, forwarding и NAT после сбросов."
                    : "Guard не запущен. Нажми «Включить», чтобы приложение поставило устойчивую автопочинку.",
                level: snapshot.guardRunning ? .ok : .warning
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
        XBOX_LIVE_MTU="1380"
        XBOX_LIVE_PORT="3074"
        ANCHOR_NAME="com.apple/xboxvpn"
        PF_RULES_FILE="/tmp/wolly_well_games.xboxvpn.pf.conf"

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
        /^[^[:space:]].*: flags=/ { iface=$1; sub(":", "", iface) }
        $1 == "inet" && iface ~ /^utun/ && $2 !~ /^127\\./ { print iface; exit }
        ')

        route_if="$(/sbin/route -n get 1.1.1.1 2>/dev/null | /usr/bin/awk '$1 == "interface:" { print $2; exit }')"
        if [[ "$route_if" == utun* ]]; then
          VPN_IF="$route_if"
        fi

        if [[ -z "${VPN_IF:-}" ]]; then
          echo "Не найден активный VPN-интерфейс utunX с IPv4."
          exit 1
        fi

        /usr/bin/printf "Включаю режим Xbox 360 Live/GTA IV: MTU %s на %s...\\n" "$XBOX_LIVE_MTU" "$VPN_IF"
        /sbin/ifconfig "$VPN_IF" mtu "$XBOX_LIVE_MTU" || true

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
        rdr pass on $VPN_IF inet proto udp from any to ($VPN_IF) port $XBOX_LIVE_PORT -> $XBOX_IP port $XBOX_LIVE_PORT
        rdr pass on $VPN_IF inet proto tcp from any to ($VPN_IF) port $XBOX_LIVE_PORT -> $XBOX_IP port $XBOX_LIVE_PORT
        pass quick on $ETH_IF inet from $SOURCE_CIDR to any keep state
        pass quick on $ETH_IF inet from any to $SOURCE_CIDR keep state
        pass quick on $VPN_IF inet proto { tcp udp icmp } from any to any keep state
        pass quick proto udp from any to any port { 53 88 500 3074 3544 4500 } keep state
        pass quick proto tcp from any to any port { 53 80 443 3074 } flags S/SA keep state
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
        echo
        echo "Ставлю системную автопочинку, чтобы macOS не сбрасывала Xbox-сеть обратно в 169.254.x.x..."
        \(buildInstallGuardScriptBody(for: config))
        echo "Guard: local.openclaw.xbox-vpn-guard установлен и запущен."
        echo "Если на Xbox всё уже выставлено, теперь можно перезагрузить Xbox и потом снова проверить статус."
        """
    }

    func buildReconnectScript(for config: ResolvedConfig) -> String {
        buildStartScript(for: config)
    }

    private func buildInstallGuardScriptBody(for config: ResolvedConfig) -> String {
        let guardScript = buildGuardScript(for: config)
        let plist = buildGuardPlist()

        return """
        /bin/mkdir -p /usr/local/sbin
        /bin/cat > /usr/local/sbin/openclaw-xbox-vpn-guard <<'GUARD_SCRIPT'
        \(guardScript)
        GUARD_SCRIPT
        /usr/sbin/chown root:wheel /usr/local/sbin/openclaw-xbox-vpn-guard
        /bin/chmod 755 /usr/local/sbin/openclaw-xbox-vpn-guard

        /bin/cat > /Library/LaunchDaemons/local.openclaw.xbox-vpn-guard.plist <<'GUARD_PLIST'
        \(plist)
        GUARD_PLIST
        /usr/sbin/chown root:wheel /Library/LaunchDaemons/local.openclaw.xbox-vpn-guard.plist
        /bin/chmod 644 /Library/LaunchDaemons/local.openclaw.xbox-vpn-guard.plist
        /bin/launchctl bootout system /Library/LaunchDaemons/local.openclaw.xbox-vpn-guard.plist >/dev/null 2>&1 || true
        /bin/launchctl bootstrap system /Library/LaunchDaemons/local.openclaw.xbox-vpn-guard.plist
        /bin/launchctl kickstart -k system/local.openclaw.xbox-vpn-guard
        """
    }

    private func buildGuardPlist() -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
          "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
          <key>Label</key>
          <string>local.openclaw.xbox-vpn-guard</string>
          <key>ProgramArguments</key>
          <array>
            <string>/usr/local/sbin/openclaw-xbox-vpn-guard</string>
          </array>
          <key>RunAtLoad</key>
          <true/>
          <key>KeepAlive</key>
          <true/>
          <key>StandardOutPath</key>
          <string>/var/log/openclaw-xbox-vpn-guard.stdout.log</string>
          <key>StandardErrorPath</key>
          <string>/var/log/openclaw-xbox-vpn-guard.stderr.log</string>
        </dict>
        </plist>
        """
    }

    private func buildGuardScript(for config: ResolvedConfig) -> String {
        """
        #!/bin/bash
        set -u

        ETH_IF="\(config.ethernetInterface)"
        MAC_IP="\(config.macAddress)"
        XBOX_IP="\(config.xboxAddress)"
        SUBNET_MASK="255.255.255.0"
        SOURCE_CIDR="10.0.0.0/24"
        XBOX_LIVE_MTU="1380"
        XBOX_LIVE_PORT="3074"
        PF_RULES_FILE="/var/run/openclaw-xbox-vpn.pf.conf"
        LOG_FILE="/var/log/openclaw-xbox-vpn-guard.log"
        CHECK_INTERVAL="10"

        log() {
          /bin/echo "$(/bin/date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG_FILE"
        }

        detect_vpn_if() {
          local route_if
          route_if="$(/sbin/route -n get 1.1.1.1 2>/dev/null | /usr/bin/awk '$1 == "interface:" { print $2; exit }')"
          if [[ "$route_if" == utun* ]]; then
            /bin/echo "$route_if"
            return 0
          fi

          /sbin/ifconfig -a | /usr/bin/awk '
            /^[^[:space:]].*: flags=/ { iface=$1; sub(":", "", iface) }
            $1 == "inet" && iface ~ /^utun/ && $2 !~ /^127\\./ { print iface; exit }
          '
        }

        interface_has_ip() {
          /sbin/ifconfig "$ETH_IF" 2>/dev/null | /usr/bin/grep -q "inet $MAC_IP "
        }

        remove_self_assigned_ips() {
          /sbin/ifconfig "$ETH_IF" 2>/dev/null | /usr/bin/awk '$1 == "inet" && $2 ~ /^169\\.254\\./ { print $2 }' | while read -r ip; do
            if [[ -n "${ip:-}" ]]; then
              /sbin/ifconfig "$ETH_IF" inet "$ip" delete >/dev/null 2>&1 || true
              log "fixed: removed self-assigned $ip from $ETH_IF"
            fi
          done
        }

        forwarding_enabled() {
          /usr/sbin/sysctl -n net.inet.ip.forwarding 2>/dev/null | /usr/bin/grep -q '^1$'
        }

        nat_points_to_vpn() {
          local vpn_if="$1"
          /sbin/pfctl -s nat 2>/dev/null | /usr/bin/grep -q "nat on $vpn_if inet from $SOURCE_CIDR to any -> ($vpn_if)"
        }

        xbox_live_forward_ready() {
          local vpn_if="$1"
          /sbin/pfctl -s nat 2>/dev/null | /usr/bin/grep -q "port = $XBOX_LIVE_PORT -> $XBOX_IP port $XBOX_LIVE_PORT"
        }

        vpn_mtu_ready() {
          local vpn_if="$1"
          /sbin/ifconfig "$vpn_if" 2>/dev/null | /usr/bin/awk -v min_mtu="$XBOX_LIVE_MTU" '
            /mtu / {
              for (i = 1; i <= NF; i++) {
                if ($i == "mtu" && (i + 1) <= NF && $(i + 1) >= min_mtu) {
                  found = 1
                }
              }
            }
            END { exit found ? 0 : 1 }
          '
        }

        ensure_state() {
          local vpn_if
          vpn_if="$(detect_vpn_if)"

          if [[ -z "${vpn_if:-}" ]]; then
            log "waiting: no IPv4 utun VPN interface"
            return 0
          fi

          if ! /sbin/ifconfig "$ETH_IF" >/dev/null 2>&1; then
            log "waiting: $ETH_IF is not present"
            return 0
          fi

          if ! /sbin/ifconfig "$ETH_IF" | /usr/bin/grep -q "status: active"; then
            log "waiting: $ETH_IF link is not active"
            return 0
          fi

          if ! forwarding_enabled; then
            /usr/sbin/sysctl -w net.inet.ip.forwarding=1 >/dev/null
            log "fixed: enabled IPv4 forwarding"
          fi

          if ! vpn_mtu_ready "$vpn_if"; then
            /sbin/ifconfig "$vpn_if" mtu "$XBOX_LIVE_MTU" >/dev/null 2>&1 || true
            log "fixed: set $vpn_if MTU to $XBOX_LIVE_MTU for Xbox 360 Live"
          fi

          if ! interface_has_ip; then
            /sbin/ifconfig "$ETH_IF" "$MAC_IP" netmask "$SUBNET_MASK" up
            log "fixed: assigned $MAC_IP/24 to $ETH_IF"
          fi

          remove_self_assigned_ips

          if ! nat_points_to_vpn "$vpn_if" || ! xbox_live_forward_ready "$vpn_if"; then
            /bin/cat > "$PF_RULES_FILE" <<EOF
        nat on $vpn_if from $SOURCE_CIDR to any -> ($vpn_if) static-port
        rdr pass on $vpn_if inet proto udp from any to ($vpn_if) port $XBOX_LIVE_PORT -> $XBOX_IP port $XBOX_LIVE_PORT
        rdr pass on $vpn_if inet proto tcp from any to ($vpn_if) port $XBOX_LIVE_PORT -> $XBOX_IP port $XBOX_LIVE_PORT
        pass quick on $ETH_IF inet from $SOURCE_CIDR to any keep state
        pass quick on $ETH_IF inet from any to $SOURCE_CIDR keep state
        pass quick on $vpn_if inet proto { tcp udp icmp } from any to any keep state
        pass quick proto udp from any to any port { 53 88 500 3074 3544 4500 } keep state
        pass quick proto tcp from any to any port { 53 80 443 3074 } flags S/SA keep state
        EOF
            /sbin/pfctl -F nat >/dev/null 2>&1 || true
            /sbin/pfctl -Ef "$PF_RULES_FILE" >/dev/null 2>&1
            log "fixed: loaded Xbox 360 Live NAT and 3074 forward $SOURCE_CIDR -> $vpn_if"
          fi

          /sbin/pfctl -k "$XBOX_IP" >/dev/null 2>&1 || true
        }

        log "started: guarding $ETH_IF for Xbox VPN"

        while true; do
          ensure_state
          /bin/sleep "$CHECK_INTERVAL"
        done
        """
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

    private func vpnMTUReady(interface name: String?, ifconfigAll: String) -> Bool {
        guard let name else {
            return false
        }

        for line in ifconfigAll.components(separatedBy: .newlines) {
            guard line.hasPrefix("\(name):") else {
                continue
            }

            let parts = line.split(whereSeparator: \.isWhitespace)
            guard let index = parts.firstIndex(of: "mtu"),
                  parts.indices.contains(parts.index(after: index)),
                  let mtu = Int(parts[parts.index(after: index)]) else {
                return false
            }

            return mtu >= 1380
        }

        return false
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
