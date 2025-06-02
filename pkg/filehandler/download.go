package filehandler

import (
	"context"
	"fmt"
	"net/http"

	"github.com/gin-gonic/gin"
	"go.uber.org/zap"
)

func (a *azureFileHandler) DownloadHandler(_ string) gin.HandlerFunc {
	return func(c *gin.Context) {
		filename := c.Param("filename")
		filename = sanitizeFilename(filename)

		a.logger.Info("File download request",
			zap.String("filename", filename),
			zap.String("client-ip", c.ClientIP()),
		)

		ctx := context.Background()
		resp, err := a.storageClient.DownloadBlob(ctx, filename)
		if err != nil {
			a.logger.Warn("Blob not found or failed to download", zap.String("filename", filename), zap.Error(err))
			c.JSON(http.StatusNotFound, gin.H{"error": "File not found"})
			return
		}
		defer resp.Body.Close()

		contentType := "application/octet-stream"
		if resp.ContentType != nil {
			contentType = *resp.ContentType
		}
		var contentLength int64 = -1
		if resp.ContentLength != nil {
			contentLength = *resp.ContentLength
		}

		a.logger.Info("Streaming file download",
			zap.String("filename", filename),
			zap.String("contentType", contentType),
			zap.Int64("size", contentLength),
		)

		c.Header("Content-Disposition", fmt.Sprintf("attachment; filename=\"%s\"", filename))
		c.DataFromReader(http.StatusOK, contentLength, contentType, resp.Body, nil)
	}
}
