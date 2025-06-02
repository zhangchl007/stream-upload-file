package storage_test

import (
	"errors"
	"os"
	"testing"

	"github.com/Azure/azure-sdk-for-go/sdk/azcore"
	"github.com/Azure/azure-sdk-for-go/sdk/azidentity"
	"github.com/stretchr/testify/assert"

	"stream-upload-file/pkg/storage"
)

// --- Mocks and helpers ---

type fakeTokenCredential struct {
	azcore.TokenCredential
}

// FakeBlobClient is a mock implementation of the BlobClient interface for testing
type FakeBlobClient struct {
	storage.BlobClient
	accountURL string
	container  string
}

func (f *FakeBlobClient) AccountURL() string {
	return "https://fakeaccount.blob.core.windows.net"
}

func (f *FakeBlobClient) Container() string {
	return "fakecontainer"
}

func setEnv(t *testing.T, key, value string) {
	t.Helper()
	old := os.Getenv(key)
	os.Setenv(key, value)
	t.Cleanup(func() { os.Setenv(key, old) })
}

func unsetEnv(t *testing.T, key string) {
	t.Helper()
	old := os.Getenv(key)
	os.Unsetenv(key)
	t.Cleanup(func() { os.Setenv(key, old) })
}

// --- Tests ---

func TestNewAzureBlobClient_MissingEnvVars(t *testing.T) {
	unsetEnv(t, "STORAGE_ACCOUNT_NAME")
	unsetEnv(t, "STORAGE_CONTAINER_NAME")
	client, err := storage.NewAzureBlobClient()
	assert.Nil(t, client)
	assert.Error(t, err)
	assert.Contains(t, err.Error(), "environment variables STORAGE_ACCOUNT_NAME and STORAGE_CONTAINER_NAME must be set")
}

func TestNewAzureBlobClient_InvalidTokenFile(t *testing.T) {
	setEnv(t, "STORAGE_ACCOUNT_NAME", "fakeaccount")
	setEnv(t, "STORAGE_CONTAINER_NAME", "fakecontainer")
	setEnv(t, "AZURE_CLIENT_ID", "fakeid")
	setEnv(t, "AZURE_TENANT_ID", "faketenant")
	setEnv(t, "AZURE_FEDERATED_TOKEN_FILE", "/tmp/definitely_not_exists_12345")

	// Patch azidentity.NewWorkloadIdentityCredential to always error
	origNewWorkloadIdentity := storage.NewWorkloadIdentityCredentialFunc
	storage.NewWorkloadIdentityCredentialFunc = func(opts *azidentity.WorkloadIdentityCredentialOptions) (*azidentity.WorkloadIdentityCredential, error) {
		return nil, errors.New("workload identity error")
	}
	defer func() { storage.NewWorkloadIdentityCredentialFunc = origNewWorkloadIdentity }()

	// Patch azidentity.NewDefaultAzureCredential to always error
	origDefaultCred := storage.NewDefaultAzureCredentialFunc
	storage.NewDefaultAzureCredentialFunc = func(opts *azidentity.DefaultAzureCredentialOptions) (*azidentity.DefaultAzureCredential, error) {
		return nil, errors.New("default credential error")
	}
	defer func() { storage.NewDefaultAzureCredentialFunc = origDefaultCred }()

	client, err := storage.NewAzureBlobClient()
	assert.Nil(t, client)
	assert.Error(t, err)
	assert.Contains(t, err.Error(), "default credential error")
}

func TestNewAzureBlobClient_SuccessWithDefaultCredential(t *testing.T) {
	setEnv(t, "STORAGE_ACCOUNT_NAME", "fakeaccount")
	setEnv(t, "STORAGE_CONTAINER_NAME", "fakecontainer")
	unsetEnv(t, "AZURE_CLIENT_ID")
	unsetEnv(t, "AZURE_TENANT_ID")
	unsetEnv(t, "AZURE_FEDERATED_TOKEN_FILE")

	// Patch azidentity.NewDefaultAzureCredential to return a fake credential
	orig := storage.NewDefaultAzureCredentialFunc
	storage.NewDefaultAzureCredentialFunc = func(opts *azidentity.DefaultAzureCredentialOptions) (*azidentity.DefaultAzureCredential, error) {
		return &azidentity.DefaultAzureCredential{}, nil
	}
	defer func() { storage.NewDefaultAzureCredentialFunc = orig }()

	// Create a local mock for BlobClient creation
	// We'll need to add NewBlobClientFunc to the storage package
	origBlob := storage.NewBlobClientFunc
	storage.NewBlobClientFunc = func(url string, cred azcore.TokenCredential, options *storage.BlobClientOptions) (storage.BlobClient, error) {
		return &FakeBlobClient{}, nil
	}
	defer func() { storage.NewBlobClientFunc = origBlob }()

	client, err := storage.NewAzureBlobClient()
	assert.NoError(t, err)
	assert.NotNil(t, client)
	assert.Equal(t, "https://fakeaccount.blob.core.windows.net", client.AccountURL())
	assert.Equal(t, "fakecontainer", client.Container())
}

func TestNewAzureBlobClient_SuccessWithWorkloadIdentity(t *testing.T) {
	setEnv(t, "STORAGE_ACCOUNT_NAME", "fakeaccount")
	setEnv(t, "STORAGE_CONTAINER_NAME", "fakecontainer")
	setEnv(t, "AZURE_CLIENT_ID", "fakeid")
	setEnv(t, "AZURE_TENANT_ID", "faketenant")
	setEnv(t, "AZURE_FEDERATED_TOKEN_FILE", "/tmp/fake_token_file")

	// Patch azidentity.NewWorkloadIdentityCredential to return a fake credential
	orig := storage.NewWorkloadIdentityCredentialFunc
	storage.NewWorkloadIdentityCredentialFunc = func(opts *azidentity.WorkloadIdentityCredentialOptions) (*azidentity.WorkloadIdentityCredential, error) {
		return &azidentity.WorkloadIdentityCredential{}, nil
	}
	defer func() { storage.NewWorkloadIdentityCredentialFunc = orig }()

	// Patch storage.NewBlobClientFunc to return a fake client
	origBlob := storage.NewBlobClientFunc
	storage.NewBlobClientFunc = func(url string, cred azcore.TokenCredential, options *storage.BlobClientOptions) (storage.BlobClient, error) {
		return &FakeBlobClient{}, nil
	}
	defer func() { storage.NewBlobClientFunc = origBlob }()

	client, err := storage.NewAzureBlobClient()
	assert.NoError(t, err)
	assert.NotNil(t, client)
	assert.Equal(t, "https://fakeaccount.blob.core.windows.net", client.AccountURL())
	assert.Equal(t, "fakecontainer", client.Container())
}
