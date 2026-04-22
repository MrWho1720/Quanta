package router

import (
	"net/http"
	"os"
	"path"
	"strings"
	"time"

	"emperror.dev/errors"
	"github.com/apex/log"
	"github.com/gin-gonic/gin"
	"github.com/google/uuid"

	"github.com/quantum/quanta/config"
	"github.com/quantum/quanta/router/middleware"
	"github.com/quantum/quanta/server"
	"github.com/quantum/quanta/server/backup"
)

// getServerBackups lists the local backup archives for a given server.
func getServerBackups(c *gin.Context) {
	s := middleware.ExtractServer(c)
	_ = s
	backupDir := config.Get().System.BackupDirectory

	entries, err := os.ReadDir(backupDir)
	if err != nil && !os.IsNotExist(err) {
		middleware.CaptureAndAbort(c, err)
		return
	}

	type BackupEntry struct {
		Uuid          string    `json:"uuid"`
		Name          string    `json:"name"`
		Bytes         int64     `json:"bytes"`
		CreatedAt     time.Time `json:"created_at"`
		IsSuccessful  bool      `json:"is_successful"`
	}

	result := make([]BackupEntry, 0)
	for _, entry := range entries {
		if entry.IsDir() {
			continue
		}
		name := entry.Name()
		if !strings.HasSuffix(name, ".tar.gz") {
			continue
		}
		backupUuid := strings.TrimSuffix(name, ".tar.gz")
		if _, err := uuid.Parse(backupUuid); err != nil {
			continue
		}
		info, err := entry.Info()
		if err != nil {
			continue
		}
		result = append(result, BackupEntry{
			Uuid:         backupUuid,
			Name:         name,
			Bytes:        info.Size(),
			CreatedAt:    info.ModTime(),
			IsSuccessful: true,
		})
	}

	c.JSON(http.StatusOK, gin.H{"data": result})
}

// postServerBackup performs a backup against a given server instance using the
// provided backup adapter.
func postServerBackup(c *gin.Context) {
	s := middleware.ExtractServer(c)
	client := middleware.ExtractApiClient(c)
	logger := middleware.ExtractLogger(c)
	var data struct {
		Adapter backup.AdapterType `json:"adapter"`
		Uuid    string             `json:"uuid"`
		Ignore  string             `json:"ignore"`
	}
	_ = c.ShouldBindJSON(&data)

	if data.Uuid == "" {
		data.Uuid = uuid.New().String()
	}
	if data.Adapter == "" {
		data.Adapter = backup.LocalBackupAdapter
	}

	var adapter backup.BackupInterface
	switch data.Adapter {
	case backup.LocalBackupAdapter:
		adapter = backup.NewLocal(client, data.Uuid, data.Ignore)
	case backup.S3BackupAdapter:
		adapter = backup.NewS3(client, data.Uuid, data.Ignore)
	default:
		middleware.CaptureAndAbort(c, errors.New("router/backups: provided adapter is not valid: "+string(data.Adapter)))
		return
	}

	adapter.WithLogContext(map[string]interface{}{
		"server":     s.ID(),
		"request_id": c.GetString("request_id"),
	})

	go func(b backup.BackupInterface, s *server.Server, logger *log.Entry) {
		if err := s.Backup(b); err != nil {
			logger.WithField("error", errors.WithStackIf(err)).Error("router: failed to generate server backup")
		}
	}(adapter, s, logger)

	c.JSON(http.StatusAccepted, gin.H{
		"attributes": gin.H{
			"uuid":          data.Uuid,
			"name":          path.Base(backup.NewLocal(client, data.Uuid, "").Path()),
			"bytes":         0,
			"created_at":    time.Now(),
			"is_successful": false,
		},
	})
}

// postServerRestoreBackup handles restoring a backup for a server by downloading
// or finding the given backup on the system and then unpacking the archive into
// the server's data directory. If the TruncateDirectory field is provided and
// is true all of the files will be deleted for the server.
//
// This endpoint will block until the backup is fully restored allowing for a
// spinner to be displayed in the Panel UI effectively.
//
// TODO: stop the server if it is running
func postServerRestoreBackup(c *gin.Context) {
	s := middleware.ExtractServer(c)
	client := middleware.ExtractApiClient(c)
	logger := middleware.ExtractLogger(c)

	var data struct {
		Adapter           backup.AdapterType `binding:"required,oneof=quanta s3" json:"adapter"`
		TruncateDirectory bool               `json:"truncate_directory"`
		// A UUID is always required for this endpoint, however the download URL
		// is only present when the given adapter type is s3.
		DownloadUrl string `json:"download_url"`
	}
	if err := c.BindJSON(&data); err != nil {
		return
	}
	if data.Adapter == backup.S3BackupAdapter && data.DownloadUrl == "" {
		c.AbortWithStatusJSON(http.StatusBadRequest, gin.H{"error": "The download_url field is required when the backup adapter is set to S3."})
		return
	}

	s.SetRestoring(true)
	hasError := true
	defer func() {
		if !hasError {
			return
		}

		s.SetRestoring(false)
	}()

	logger.Info("processing server backup restore request")
	if data.TruncateDirectory {
		logger.Info("received \"truncate_directory\" flag in request: deleting server files")
		if err := s.Filesystem().TruncateRootDirectory(); err != nil {
			middleware.CaptureAndAbort(c, err)
			return
		}
	}

	// Now that we've cleaned up the data directory if necessary, grab the backup file
	// and attempt to restore it into the server directory.
	if data.Adapter == backup.LocalBackupAdapter {
		b, _, err := backup.LocateLocal(client, c.Param("backup"))
		if err != nil {
			middleware.CaptureAndAbort(c, err)
			return
		}
		go func(s *server.Server, b backup.BackupInterface, logger *log.Entry) {
			logger.Info("starting restoration process for server backup using local driver")
			if err := s.RestoreBackup(b, nil); err != nil {
				logger.WithField("error", err).Error("failed to restore local backup to server")
			}
			s.Events().Publish(server.DaemonMessageEvent, "Completed server restoration from local backup.")
			s.Events().Publish(server.BackupRestoreCompletedEvent, "")
			logger.Info("completed server restoration from local backup")
			s.SetRestoring(false)
		}(s, b, logger)
		hasError = false
		c.Status(http.StatusAccepted)
		return
	}

	// Since this is not a local backup we need to stream the archive and then
	// parse over the contents as we go in order to restore it to the server.
	httpClient := http.Client{}
	logger.Info("downloading backup from remote location...")
	// TODO: this will hang if there is an issue. We can't use c.Request.Context() (or really any)
	//  since it will be canceled when the request is closed which happens quickly since we push
	//  this into the background.
	//
	// For now I'm just using the server context so at least the request is canceled if
	// the server gets deleted.
	req, err := http.NewRequestWithContext(s.Context(), http.MethodGet, data.DownloadUrl, nil)
	if err != nil {
		middleware.CaptureAndAbort(c, err)
		return
	}
	res, err := httpClient.Do(req)
	if err != nil {
		middleware.CaptureAndAbort(c, err)
		return
	}
	// Don't allow content types that we know are going to give us problems.
	if res.Header.Get("Content-Type") == "" || !strings.Contains("application/x-gzip application/gzip", res.Header.Get("Content-Type")) {
		_ = res.Body.Close()
		c.AbortWithStatusJSON(http.StatusBadRequest, gin.H{
			"error": "The provided backup link is not a supported content type. \"" + res.Header.Get("Content-Type") + "\" is not application/x-gzip.",
		})
		return
	}

	go func(s *server.Server, uuid string, logger *log.Entry) {
		logger.Info("starting restoration process for server backup using S3 driver")
		if err := s.RestoreBackup(backup.NewS3(client, uuid, ""), res.Body); err != nil {
			logger.WithField("error", errors.WithStack(err)).Error("failed to restore remote S3 backup to server")
		}
		s.Events().Publish(server.DaemonMessageEvent, "Completed server restoration from S3 backup.")
		s.Events().Publish(server.BackupRestoreCompletedEvent, "")
		logger.Info("completed server restoration from S3 backup")
		s.SetRestoring(false)
	}(s, c.Param("backup"), logger)

	hasError = false
	c.Status(http.StatusAccepted)
}

// deleteServerBackup deletes a local backup of a server. If the backup is not
// found on the machine just return a 404 error. The service calling this
// endpoint can make its own decisions as to how it wants to handle that
// response.
func deleteServerBackup(c *gin.Context) {
	b, _, err := backup.LocateLocal(middleware.ExtractApiClient(c), c.Param("backup"))
	if err != nil {
		// Just return from the function at this point if the backup was not located.
		if errors.Is(err, os.ErrNotExist) {
			c.AbortWithStatusJSON(http.StatusNotFound, gin.H{
				"error": "The requested backup was not found on this server.",
			})
			return
		}
		middleware.CaptureAndAbort(c, err)
		return
	}
	// I'm not entirely sure how likely this is to happen, however if we did manage to
	// locate the backup previously and it is now missing when we go to delete, just
	// treat it as having been successful, rather than returning a 404.
	if err := b.Remove(); err != nil && !errors.Is(err, os.ErrNotExist) {
		middleware.CaptureAndAbort(c, err)
		return
	}
	c.Status(http.StatusNoContent)
}
