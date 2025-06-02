package filehandler

import (
	"context"
	"io"

	"github.com/Azure/azure-sdk-for-go/sdk/storage/azblob"
	"go.uber.org/zap"
)

type StorageClient interface {
	UploadBlob(ctx context.Context, blobName string, data io.Reader, options *azblob.UploadStreamOptions) error
	DownloadBlob(ctx context.Context, blobName string) (*azblob.DownloadStreamResponse, error)
}

type azureFileHandler struct {
	logger        *zap.Logger
	storageClient StorageClient
}

func NewAzureFileHandler(client StorageClient) *azureFileHandler {
	return &azureFileHandler{
		logger:        zap.L().Named("azure-file-handler"),
		storageClient: client,
	}
}
