package filehandler_test

import (
	"bytes"
	"context"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"strconv"
	"testing"

	"github.com/gin-gonic/gin"
	"github.com/stretchr/testify/assert"
	"go.uber.org/zap"
)

// Mock types for testing
type mockStorageClient struct {
	downloadFunc func(ctx context.Context, filename string) (*mockDownloadResponse, error)
}

type mockDownloadResponse struct {
	Body          io.ReadCloser
	ContentType   *string
	ContentLength *int64
}

func (m *mockStorageClient) DownloadBlob(ctx context.Context, filename string) (*mockDownloadResponse, error) {
	return m.downloadFunc(ctx, filename)
}

type testLogger struct{}

func (t *testLogger) Info(msg string, fields ...zap.Field)  {}
func (t *testLogger) Warn(msg string, fields ...zap.Field)  {}
func (t *testLogger) Error(msg string, fields ...zap.Field) {}

type azureFileHandler struct {
	storageClient interface {
		DownloadBlob(ctx context.Context, filename string) (*mockDownloadResponse, error)
	}
	logger interface {
		Info(msg string, fields ...zap.Field)
		Warn(msg string, fields ...zap.Field)
		Error(msg string, fields ...zap.Field)
	}
}

func (h *azureFileHandler) DownloadHandler(basePath string) gin.HandlerFunc {
	return func(c *gin.Context) {
		// Implementation details should match how it's used in the tests
		filename := c.Param("filename")
		resp, err := h.storageClient.DownloadBlob(c.Request.Context(), filename)
		if err != nil {
			c.JSON(http.StatusNotFound, gin.H{"error": "File not found"})
			return
		}

		defer resp.Body.Close()

		contentType := "application/octet-stream"
		if resp.ContentType != nil {
			contentType = *resp.ContentType
		}

		c.Header("Content-Disposition", `attachment; filename="`+filename+`"`)
		c.Header("Content-Type", contentType)
		if resp.ContentLength != nil {
			c.Header("Content-Length", strconv.FormatInt(*resp.ContentLength, 10))
		}
	}

}

func newTestAzureFileHandler(downloadFunc func(ctx context.Context, filename string) (*mockDownloadResponse, error)) *azureFileHandler {
	return &azureFileHandler{
		storageClient: &mockStorageClient{downloadFunc: downloadFunc},
		logger:        &testLogger{},
	}
}

func TestDownloadHandler_Success(t *testing.T) {
	gin.SetMode(gin.TestMode)
	expectedContent := []byte("hello world")
	contentType := "text/plain"
	contentLength := int64(len(expectedContent))

	handler := newTestAzureFileHandler(func(ctx context.Context, filename string) (*mockDownloadResponse, error) {
		return &mockDownloadResponse{
			Body:          io.NopCloser(bytes.NewReader(expectedContent)),
			ContentType:   &contentType,
			ContentLength: &contentLength,
		}, nil
	})

	router := gin.New()
	router.GET("/download/:filename", handler.DownloadHandler(""))

	req := httptest.NewRequest("GET", "/download/test.txt", nil)
	w := httptest.NewRecorder()
	router.ServeHTTP(w, req)

	assert.Equal(t, http.StatusOK, w.Code)
	assert.Equal(t, "attachment; filename=\"test.txt\"", w.Header().Get("Content-Disposition"))
	assert.Equal(t, contentType, w.Header().Get("Content-Type"))
	assert.Equal(t, string(expectedContent), w.Body.String())
}

func TestDownloadHandler_NotFound(t *testing.T) {
	gin.SetMode(gin.TestMode)
	handler := newTestAzureFileHandler(func(ctx context.Context, filename string) (*mockDownloadResponse, error) {
		return nil, errors.New("not found")
	})

	router := gin.New()
	router.GET("/download/:filename", handler.DownloadHandler(""))

	req := httptest.NewRequest("GET", "/download/missing.txt", nil)
	w := httptest.NewRecorder()
	router.ServeHTTP(w, req)

	assert.Equal(t, http.StatusNotFound, w.Code)
	assert.Contains(t, w.Body.String(), "File not found")
}

func TestDownloadHandler_DefaultContentTypeAndLength(t *testing.T) {
	gin.SetMode(gin.TestMode)
	expectedContent := []byte("abc123")

	handler := newTestAzureFileHandler(func(ctx context.Context, filename string) (*mockDownloadResponse, error) {
		return &mockDownloadResponse{
			Body:          io.NopCloser(bytes.NewReader(expectedContent)),
			ContentType:   nil,
			ContentLength: nil,
		}, nil
	})

	router := gin.New()
	router.GET("/download/:filename", handler.DownloadHandler(""))

	req := httptest.NewRequest("GET", "/download/abc.txt", nil)
	w := httptest.NewRecorder()
	router.ServeHTTP(w, req)

	assert.Equal(t, http.StatusOK, w.Code)
	assert.Equal(t, "application/octet-stream", w.Header().Get("Content-Type"))
	assert.Equal(t, string(expectedContent), w.Body.String())
}

func TestDownloadHandler_SanitizeFilename(t *testing.T) {
	gin.SetMode(gin.TestMode)
	expectedContent := []byte("safe")
	handler := newTestAzureFileHandler(func(ctx context.Context, filename string) (*mockDownloadResponse, error) {
		// Should only receive the base name, not a path
		if filename != "evil.txt" {
			t.Errorf("filename not sanitized: got %q", filename)
		}
		return &mockDownloadResponse{
			Body:          io.NopCloser(bytes.NewReader(expectedContent)),
			ContentType:   nil,
			ContentLength: nil,
		}, nil
	})

	router := gin.New()
	router.GET("/download/:filename", handler.DownloadHandler(""))

	req := httptest.NewRequest("GET", "/download/../../evil.txt", nil)
	w := httptest.NewRecorder()
	router.ServeHTTP(w, req)

	assert.Equal(t, http.StatusOK, w.Code)
	assert.Equal(t, string(expectedContent), w.Body.String())
}
