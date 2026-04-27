package router

import (
	"crypto/md5"
	"crypto/sha1"
	"crypto/sha256"
	"crypto/sha512"
	"encoding/binary"
	"encoding/hex"
	"fmt"
	"hash/crc32"
	"io"
	"net/http"
	"strings"
	"sync"

	"github.com/gin-gonic/gin"
	"github.com/quantum/quanta/router/middleware"
)

// murmurHash2 implements the specific MurmurHash2 variant that CurseForge uses
// for plugin fingerprinting. Whitespace bytes (9, 10, 13, 32) are stripped before hashing.
func murmurHash2(data []byte) uint32 {
	// Strip whitespace bytes as per CF spec
	filtered := make([]byte, 0, len(data))
	for _, b := range data {
		if b != 9 && b != 10 && b != 13 && b != 32 {
			filtered = append(filtered, b)
		}
	}

	const m uint32 = 0x5bd1e995
	const r = 24
	seed := uint32(1)
	length := uint32(len(filtered))

	h := seed ^ length
	i := 0

	for length >= 4 {
		k := binary.LittleEndian.Uint32(filtered[i : i+4])
		k *= m
		k ^= k >> r
		k *= m
		h *= m
		h ^= k
		i += 4
		length -= 4
	}

	switch length {
	case 3:
		h ^= uint32(filtered[i+2]) << 16
		fallthrough
	case 2:
		h ^= uint32(filtered[i+1]) << 8
		fallthrough
	case 1:
		h ^= uint32(filtered[i])
		h *= m
	}

	h ^= h >> 13
	h *= m
	h ^= h >> 15

	return h
}

// hashFile computes the requested hash algorithm on the given reader.
// Returns the hex-encoded result (or decimal string for curseforge).
func hashFile(r io.Reader, algorithm string) (string, error) {
	switch algorithm {
	case "md5":
		h := md5.New()
		if _, err := io.Copy(h, r); err != nil {
			return "", err
		}
		return hex.EncodeToString(h.Sum(nil)), nil

	case "sha1":
		h := sha1.New()
		if _, err := io.Copy(h, r); err != nil {
			return "", err
		}
		return hex.EncodeToString(h.Sum(nil)), nil

	case "sha256":
		h := sha256.New()
		if _, err := io.Copy(h, r); err != nil {
			return "", err
		}
		return hex.EncodeToString(h.Sum(nil)), nil

	case "sha384":
		h := sha512.New384()
		if _, err := io.Copy(h, r); err != nil {
			return "", err
		}
		return hex.EncodeToString(h.Sum(nil)), nil

	case "sha512":
		h := sha512.New()
		if _, err := io.Copy(h, r); err != nil {
			return "", err
		}
		return hex.EncodeToString(h.Sum(nil)), nil

	case "crc32":
		h := crc32.NewIEEE()
		if _, err := io.Copy(h, r); err != nil {
			return "", err
		}
		return fmt.Sprintf("%d", h.Sum32()), nil

	case "curseforge":
		data, err := io.ReadAll(r)
		if err != nil {
			return "", err
		}
		return fmt.Sprintf("%d", murmurHash2(data)), nil

	default:
		return "", fmt.Errorf("unsupported algorithm: %s", algorithm)
	}
}

type fingerprintResult struct {
	path string
	hash string
	err  string
}

// getServerFileFingerprints handles GET /api/servers/:server/files/fingerprints
//
// Query parameters:
//
//	algorithm  - hash algorithm: md5, sha1, sha256, sha384, sha512, crc32, curseforge (default: sha512)
//	files[]    - one or more file paths relative to the server root (can be repeated)
func getServerFileFingerprints(c *gin.Context) {
	s := middleware.ExtractServer(c)

	algorithm := strings.ToLower(c.DefaultQuery("algorithm", "sha512"))
	validAlgorithms := map[string]bool{
		"md5": true, "sha1": true, "sha256": true, "sha384": true,
		"sha512": true, "crc32": true, "curseforge": true,
	}
	if !validAlgorithms[algorithm] {
		c.AbortWithStatusJSON(http.StatusBadRequest, gin.H{
			"error": fmt.Sprintf("unsupported algorithm '%s'; valid: md5, sha1, sha256, sha384, sha512, crc32, curseforge", algorithm),
		})
		return
	}

	rawPaths := c.QueryArray("files[]")
	if len(rawPaths) == 0 {
		rawPaths = c.QueryArray("files")
	}
	if len(rawPaths) == 0 {
		c.JSON(http.StatusOK, gin.H{"fingerprints": gin.H{}})
		return
	}

	type workItem struct {
		path string
	}

	results := make([]fingerprintResult, len(rawPaths))
	var wg sync.WaitGroup

	for idx, rawPath := range rawPaths {
		wg.Add(1)
		go func(i int, p string) {
			defer wg.Done()
			cleanPath := strings.TrimLeft(p, "/")
			results[i].path = cleanPath

			f, _, err := s.Filesystem().File(cleanPath)
			if err != nil {
				results[i].err = err.Error()
				return
			}
			defer f.Close()

			hash, err := hashFile(f, algorithm)
			if err != nil {
				results[i].err = err.Error()
				return
			}
			results[i].hash = hash
		}(idx, rawPath)
	}

	wg.Wait()

	fingerprints := make(map[string]any, len(results))
	for _, r := range results {
		if r.err != "" {
			fingerprints[r.path] = gin.H{"error": r.err}
		} else {
			fingerprints[r.path] = r.hash
		}
	}

	c.JSON(http.StatusOK, gin.H{
		"algorithm":    algorithm,
		"fingerprints": fingerprints,
	})
}
