package mdns

import (
	"fmt"
	"log"
	"net"
	"os"
	"strings"

	"github.com/hashicorp/mdns"
)

type MDNSServer struct {
	server *mdns.Server
	port   int
}

// New создаёт и запускает mDNS сервер
func New(port int, version string) (*MDNSServer, error) {
	hostname, err := os.Hostname()
	if err != nil {
		hostname = "homelan-server"
	}
	// mDNS не любит пробелы в именах хостов
	hostname = strings.ReplaceAll(hostname, " ", "-")
	// Убираем .local если есть, либа сама добавит
	hostname = strings.TrimSuffix(hostname, ".local")

	// Получаем ТОЛЬКО нормальные IP (без докера и vpn)
	ips, err := getRealLocalIPs()
	if err != nil {
		return nil, fmt.Errorf("failed to get local IPs: %w", err)
	}

	if len(ips) == 0 {
		return nil, fmt.Errorf("no usable local IP addresses found")
	}

	log.Printf("📡 mDNS: Advertising service '_homelan._tcp' on IPs: %v", ips)

	service, err := mdns.NewMDNSService(
		hostname,        // Instance Name (например "orange-pi")
		"_homelan._tcp", // Service Type (важно для поиска)
		"",              // Domain (local)
		"",              // Hostname
		port,            // Port
		ips,             // IPs
		[]string{ // TXT records info
			"version=" + version,
			"name=HomeLAN Server",
		},
	)
	if err != nil {
		return nil, fmt.Errorf("failed to create service: %w", err)
	}

	// Создаем сервер, который будет отвечать на запросы
	server, err := mdns.NewServer(&mdns.Config{Zone: service})
	if err != nil {
		// Частая ошибка на Linux: порт 5353 занят Avahi
		return nil, fmt.Errorf("failed to bind port 5353 (conflict with avahi-daemon?): %w", err)
	}

	log.Printf("📡 mDNS: Started. Discovery name: %s.local", hostname)

	return &MDNSServer{
		server: server,
		port:   port,
	}, nil
}

func (m *MDNSServer) Stop() {
	if m.server != nil {
		m.server.Shutdown()
		log.Println("📡 mDNS: Stopped")
	}
}

// getRealLocalIPs фильтрует всякий мусор типа Docker-сетей
func getRealLocalIPs() ([]net.IP, error) {
	var ips []net.IP

	interfaces, err := net.Interfaces()
	if err != nil {
		return nil, err
	}

	for _, iface := range interfaces {
		// Пропускаем выключенные и loopback
		if iface.Flags&net.FlagUp == 0 || iface.Flags&net.FlagLoopback != 0 {
			continue
		}

		// Хак: пропускаем интерфейсы Докера (обычно docker0, br-..., veth...)
		if strings.HasPrefix(iface.Name, "docker") || strings.HasPrefix(iface.Name, "br-") {
			continue
		}

		addrs, err := iface.Addrs()
		if err != nil {
			continue
		}

		for _, addr := range addrs {
			var ip net.IP
			switch v := addr.(type) {
			case *net.IPNet:
				ip = v.IP
			case *net.IPAddr:
				ip = v.IP
			}

			if ip == nil || ip.IsLoopback() {
				continue
			}

			// Берем только IPv4
			ip = ip.To4()
			if ip == nil {
				continue
			}

			// Дополнительная проверка: нас интересуют только частные сети
			// 192.168.x.x, 10.x.x.x, 172.16-31.x.x
			if isPrivateIP(ip) {
				ips = append(ips, ip)
			}
		}
	}

	return ips, nil
}

// Проверка на принадлежность к локальным сетям
func isPrivateIP(ip net.IP) bool {
	// 10.0.0.0/8
	if ip[0] == 10 {
		return true
	}
	// 172.16.0.0/12 (Докер обычно тут, но мы фильтруем интерфейсы по имени, так что ок)
	if ip[0] == 172 && ip[1] >= 16 && ip[1] <= 31 {
		return true
	}
	// 192.168.0.0/16 (Самое частое для дома)
	if ip[0] == 192 && ip[1] == 168 {
		return true
	}
	return false
}
