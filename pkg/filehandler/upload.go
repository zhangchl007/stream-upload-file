package filehandler

import (
	"context"
	"net/http"
	"path/filepath"
	"strings"

	"github.com/Azure/azure-sdk-for-go/sdk/storage/azblob"
	"github.com/Azure/azure-sdk-for-go/sdk/storage/azblob/blob"
	"github.com/gin-gonic/gin"
	"go.uber.org/zap"
)

func (a *azureFileHandler) UploadHandler(_ string) gin.HandlerFunc {
	return func(c *gin.Context) {
		file, header, err := c.Request.FormFile("file")
		if err != nil {
			a.logger.Error("Failed to get file from request", zap.Error(err))
			c.JSON(http.StatusBadRequest, gin.H{"error": "Failed to get file"})
			return
		}
		defer file.Close()

		filename := sanitizeFilename(header.Filename)

		a.logger.Info("File upload attempt",
			zap.String("filename", filename),
			zap.Int64("size", header.Size),
			zap.String("content-type", header.Header.Get("Content-Type")),
			zap.String("client-ip", c.ClientIP()),
		)

		if header.Size > 100*1024*1024 {
			a.logger.Warn("File too large", zap.Int64("size", header.Size))
			c.JSON(http.StatusBadRequest, gin.H{"error": "File too large (max 100MB)"})
			return
		}

		ctx := context.Background()
		contentType := header.Header.Get("Content-Type")
		if contentType == "" {
			contentType = "application/octet-stream"
		}

		options := azblob.UploadStreamOptions{
			HTTPHeaders: &blob.HTTPHeaders{
				BlobContentType: &contentType,
			},
			Metadata: map[string]*string{
				"originalName": stringPtr(header.Filename),
				"uploadedBy":   stringPtr(c.GetHeader("User-Agent")),
			},
		}

		err = a.storageClient.UploadBlob(ctx, filename, file, &options)
		if err != nil {
			a.logger.Error("Failed to upload to Azure Blob", zap.Error(err))
			c.JSON(http.StatusInternalServerError, gin.H{"error": "Failed to store file"})
			return
		}

		a.logger.Info("File uploaded and overwritten successfully", zap.String("filename", filename))
		c.JSON(http.StatusOK, gin.H{
			"message":   "File uploaded and overwritten successfully",
			"filename":  filename,
			"overwrote": true,
		})
	}
}

func sanitizeFilename(filename string) string {
	filename = filepath.Base(filename)
	filename = strings.ReplaceAll(filename, " ", "_")
	return filename
}

func stringPtr(s string) *string {
	return &s
}
