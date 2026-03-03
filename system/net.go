//go:build linux
// +build linux

package system

import (
	"net"
	"syscall"
	"unsafe"

	"emperror.dev/errors"
	"github.com/apex/log"
)

// ifreqMTU is the structure used for SIOCGIFMTU ioctl call
type ifreqMTU struct {
	name [syscall.IFNAMSIZ]byte
	mtu  uint32
	_    [20]byte // padding to reach sizeof(struct ifreq)
}

// GetDefaultInterfaceMTU detects the MTU of the default host network interface.
// It uses a UDP "dial" to a public IP (8.8.8.8) to find the local IP used for
// internet traffic, then looks up that interface's MTU.
// Returns the detected MTU value (defaults to 1500 if detection fails).
func GetDefaultInterfaceMTU() (int, error) {
	// Use UDP to determine the default route without actually making a connection
	conn, err := net.Dial("udp", "8.8.8.8:53")
	if err != nil {
		log.WithField("error", err).Warn("failed to dial UDP to determine default interface")
		return 1500, errors.Wrap(err, "system/net: failed to dial UDP")
	}
	defer conn.Close()

	// Get the local address that would be used for this connection
	localAddr := conn.LocalAddr().(*net.UDPAddr)
	localIP := localAddr.IP

	// Find the interface with this IP
	iface, err := findInterfaceByIP(localIP)
	if err != nil {
		log.WithField("error", err).WithField("ip", localIP).Warn("failed to find interface for local IP")
		return 1500, errors.Wrap(err, "system/net: failed to find interface")
	}

	// Get the MTU of the interface using syscall
	mtu, err := getInterfaceMTU(iface.Name)
	if err != nil {
		log.WithField("error", err).WithField("interface", iface.Name).Warn("failed to get MTU for interface")
		return 1500, errors.Wrap(err, "system/net: failed to get MTU")
	}

	log.WithField("interface", iface.Name).WithField("mtu", mtu).Info("detected host MTU")

	return mtu, nil
}

// findInterfaceByIP finds the network interface that has the given IP address.
func findInterfaceByIP(ip net.IP) (*net.Interface, error) {
	interfaces, err := net.Interfaces()
	if err != nil {
		return nil, err
	}

	for _, iface := range interfaces {
		// Skip down interfaces and loopback
		if iface.Flags&net.FlagUp == 0 || iface.Flags&net.FlagLoopback != 0 {
			continue
		}

		addrs, err := iface.Addrs()
		if err != nil {
			continue
		}

		for _, addr := range addrs {
			switch v := addr.(type) {
			case *net.IPNet:
				if v.IP.Equal(ip) {
					return &iface, nil
				}
			case *net.IPAddr:
				if v.IP.Equal(ip) {
					return &iface, nil
				}
			}
		}
	}

	return nil, errors.New("no interface found with the given IP")
}

// getInterfaceMTU returns the MTU of the given network interface using ioctl.
func getInterfaceMTU(name string) (int, error) {
	sock, err := syscall.Socket(syscall.AF_INET, syscall.SOCK_DGRAM, 0)
	if err != nil {
		return 0, err
	}
	defer syscall.Close(sock)

	var req ifreqMTU
	copy(req.name[:], name)

	_, _, errno := syscall.Syscall(
		syscall.SYS_IOCTL,
		uintptr(sock),
		syscall.SIOCGIFMTU,
		uintptr(unsafe.Pointer(&req)),
	)
	if errno != 0 {
		return 0, errno
	}

	return int(req.mtu), nil
}

// GetEffectiveMTU returns the MTU to use based on configuration.
// If configMTU is 0 (auto), it detects the host's default interface MTU.
// Otherwise, it returns the configured value.
func GetEffectiveMTU(configMTU int64) int64 {
	if configMTU != 0 {
		// Manual MTU configured, use that value
		return configMTU
	}

	// Auto-detect MTU
	log.Info("network_mtu is 0, auto-detecting host interface MTU...")
	mtu, err := GetDefaultInterfaceMTU()
	if err != nil {
		log.WithField("error", err).Warn("failed to auto-detect MTU, using fallback value 1500")
		return 1500
	}

	log.WithField("mtu", mtu).Info("detected host MTU; applying to docker network")
	return int64(mtu)
}
