package storage

import (
	"context"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"time"

	"github.com/Azure/azure-sdk-for-go/sdk/azcore"
	"github.com/Azure/azure-sdk-for-go/sdk/azcore/policy"
	"github.com/Azure/azure-sdk-for-go/sdk/azidentity"
	"github.com/Azure/azure-sdk-for-go/sdk/storage/azblob"
	"go.uber.org/zap"
)

type AzureBlobClient struct {
	client     *azblob.Client
	accountURL string
	container  string
	logger     *zap.Logger
}

// For testing
var NewDefaultAzureCredentialFunc = azidentity.NewDefaultAzureCredential
var NewWorkloadIdentityCredentialFunc = azidentity.NewWorkloadIdentityCredential

type BlobClientOptions struct {
	*azblob.ClientOptions
}

type BlobClient interface {
	UploadStream(ctx context.Context, containerName string, blobName string, body io.Reader, options *azblob.UploadStreamOptions) (azblob.UploadStreamResponse, error)
	DownloadStream(ctx context.Context, containerName string, blobName string, options *azblob.DownloadStreamOptions) (azblob.DownloadStreamResponse, error)
}

var NewBlobClientFunc = func(url string, cred azcore.TokenCredential, options *BlobClientOptions) (BlobClient, error) {
	var clientOptions *azblob.ClientOptions
	if options != nil {
		clientOptions = options.ClientOptions
	}
	return azblob.NewClient(url, cred, clientOptions)
}

// Container returns the container name
func (c *AzureBlobClient) Container() string {
	return c.container
}

// AccountURL returns the Azure Blob Storage account URL
func (a *AzureBlobClient) AccountURL() string {
	return a.accountURL
}

func NewAzureBlobClient() (*AzureBlobClient, error) {
	logger := zap.L().Named("azure-blob-client")

	// Get required environment variables
	storageAccountName := os.Getenv("STORAGE_ACCOUNT_NAME")
	containerName := os.Getenv("STORAGE_CONTAINER_NAME")

	if storageAccountName == "" || containerName == "" {
		logger.Error("Missing required environment variables",
			zap.String("STORAGE_ACCOUNT_NAME", storageAccountName),
			zap.String("STORAGE_CONTAINER_NAME", containerName))
		return nil, fmt.Errorf("environment variables STORAGE_ACCOUNT_NAME and STORAGE_CONTAINER_NAME must be set")
	}

	// Construct the account URL
	accountURL := fmt.Sprintf("https://%s.blob.core.windows.net", storageAccountName)

	// Get workload identity credentials
	clientID := os.Getenv("AZURE_CLIENT_ID")
	tenantID := os.Getenv("AZURE_TENANT_ID")
	tokenFilePath := os.Getenv("AZURE_FEDERATED_TOKEN_FILE")

	// Validate token file exists
	if tokenFilePath != "" {
		if _, err := os.Stat(tokenFilePath); os.IsNotExist(err) {
			tokenDir := filepath.Dir(tokenFilePath)
			logger.Error("Token file does not exist",
				zap.String("path", tokenFilePath),
				zap.String("directory", tokenDir))

			// List files in directory to help debug
			if files, err := os.ReadDir(tokenDir); err == nil {
				fileNames := make([]string, 0)
				for _, file := range files {
					fileNames = append(fileNames, file.Name())
				}
				logger.Info("Files in token directory", zap.Strings("files", fileNames))
			}
		}
	}
	var cred azcore.TokenCredential
	var err error

	// Try workload identity first
	if clientID != "" && tenantID != "" && tokenFilePath != "" {
		logger.Info("Using workload identity authentication")
		cred, err = azidentity.NewWorkloadIdentityCredential(&azidentity.WorkloadIdentityCredentialOptions{
			ClientID:      clientID,
			TenantID:      tenantID,
			TokenFilePath: tokenFilePath,
		})

		if err != nil {
			logger.Error("Failed to create workload identity credential", zap.Error(err))
			cred = nil // Explicitly set to nil to fall back
		}
	}

	// Fall back to default credential if workload identity failed
	if cred == nil {
		logger.Info("Falling back to default Azure credential")
		cred, err = azidentity.NewDefaultAzureCredential(nil)
		if err != nil {
			logger.Error("Failed to create default Azure credential", zap.Error(err))
			return nil, err
		}
	}

	// Create the blob client with retry options
	clientOptions := &azblob.ClientOptions{
		ClientOptions: policy.ClientOptions{
			Retry: policy.RetryOptions{
				MaxRetries:    3,
				RetryDelay:    4 * time.Second,
				MaxRetryDelay: 60 * time.Second,
			},
		},
	}

	client, err := azblob.NewClient(accountURL, cred, clientOptions)
	if err != nil {
		logger.Error("Failed to create Azure Blob client", zap.Error(err))
		return nil, err
	}

	// Verify container exists by listing blobs (limited to 1)
	containerClient := client.ServiceClient().NewContainerClient(containerName)
	maxResults := int32(1)
	pager := containerClient.NewListBlobsFlatPager(&azblob.ListBlobsFlatOptions{
		MaxResults: &maxResults,
	})

	ctx := context.Background()
	if _, err := pager.NextPage(ctx); err != nil {
		logger.Warn("Container may not exist or access denied",
			zap.String("container", containerName),
			zap.Error(err))

		// Try to create the container (ignoring any errors if it already exists)
		_, _ = containerClient.Create(ctx, nil)
	}

	logger.Info("Successfully connected to Azure Blob Storage",
		zap.String("account", storageAccountName),
		zap.String("container", containerName))

	return &AzureBlobClient{
		client:     client,
		accountURL: accountURL,
		container:  containerName,
		logger:     logger,
	}, nil
}

func (a *AzureBlobClient) UploadBlob(ctx context.Context, blobName string, data io.Reader, options *azblob.UploadStreamOptions) error {
	_, err := a.client.UploadStream(ctx, a.container, blobName, data, options)
	return err
}

func (a *AzureBlobClient) DownloadBlob(ctx context.Context, blobName string) (*azblob.DownloadStreamResponse, error) {
	resp, err := a.client.DownloadStream(ctx, a.container, blobName, nil)
	if err != nil {
		return nil, err
	}
	return &resp, nil
}
