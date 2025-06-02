package filehandler_test

import (
	"context"
	"errors"
	"io"
	"reflect"
	"strings"
	"testing"

	"stream-upload-file/pkg/filehandler"

	"github.com/Azure/azure-sdk-for-go/sdk/storage/azblob"
	"github.com/stretchr/testify/assert"
)

// MockStorageClient implements the StorageClient interface for testing
type MockStorageClient struct {
	uploadCalled   bool
	downloadCalled bool
	uploadErr      error
	downloadResp   *azblob.DownloadStreamResponse
	downloadErr    error
}

func (m *MockStorageClient) UploadBlob(ctx context.Context, blobName string, data io.Reader, options *azblob.UploadStreamOptions) error {
	m.uploadCalled = true
	return m.uploadErr
}

func (m *MockStorageClient) DownloadBlob(ctx context.Context, blobName string) (*azblob.DownloadStreamResponse, error) {
	m.downloadCalled = true
	return m.downloadResp, m.downloadErr
}

func TestNewAzureFileHandler_InitializesFields(t *testing.T) {
	mockClient := &MockStorageClient{}
	handler := filehandler.NewAzureFileHandler(mockClient)

	assert.NotNil(t, handler)
	assert.NotNil(t, getUnexportedField(handler, "logger"))
	assert.Equal(t, mockClient, getUnexportedField(handler, "storageClient"))
}

// Helper function to access unexported fields using reflection
func getUnexportedField(obj interface{}, field string) interface{} {
	val := reflect.ValueOf(obj).Elem().FieldByName(field)
	return val.Interface()
}

func TestStorageClient_UploadBlob_Called(t *testing.T) {
	mockClient := &MockStorageClient{}

	err := mockClient.UploadBlob(context.Background(), "test.txt", strings.NewReader("data"), &azblob.UploadStreamOptions{})
	assert.True(t, mockClient.uploadCalled)
	assert.NoError(t, err)
}

func TestStorageClient_UploadBlob_Error(t *testing.T) {
	mockClient := &MockStorageClient{uploadErr: errors.New("upload failed")}

	err := mockClient.UploadBlob(context.Background(), "test.txt", strings.NewReader("data"), &azblob.UploadStreamOptions{})
	assert.True(t, mockClient.uploadCalled)
	assert.EqualError(t, err, "upload failed")
}

func TestStorageClient_DownloadBlob_Called(t *testing.T) {
	mockClient := &MockStorageClient{}

	resp, err := mockClient.DownloadBlob(context.Background(), "test.txt")
	assert.True(t, mockClient.downloadCalled)
	assert.Nil(t, resp)
	assert.NoError(t, err)
}

func TestStorageClient_DownloadBlob_Error(t *testing.T) {
	mockClient := &MockStorageClient{downloadErr: errors.New("not found")}

	resp, err := mockClient.DownloadBlob(context.Background(), "test.txt")
	assert.True(t, mockClient.downloadCalled)
	assert.Nil(t, resp)
	assert.EqualError(t, err, "not found")
}
