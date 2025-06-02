package filehandler_test

import (
	"bytes"
	"io"
	"mime/multipart"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/gin-gonic/gin"
	"github.com/stretchr/testify/assert"
)

func createMultipartRequest(t *testing.T, fieldName, filename, content string) (*http.Request, *multipart.Writer) {
	body := &bytes.Buffer{}
	writer := multipart.NewWriter(body)
	part, err := writer.CreateFormFile(fieldName, filename)
	assert.NoError(t, err)
	_, err = io.Copy(part, strings.NewReader(content))
	assert.NoError(t, err)
	writer.Close()
	req := httptest.NewRequest("POST", "/upload", body)
	req.Header.Set("Content-Type", writer.FormDataContentType())
	return req, writer
}

// uploadHandler is a mock function to simulate the upload handler
func uploadHandler(c *gin.Context) {
	file, header, err := c.Request.FormFile("file")
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "Failed to get file"})
		return
	}
	defer file.Close()

	if header.Size > 100*1024*1024 {
		c.JSON(http.StatusBadRequest, gin.H{"error": "File too large (max 100MB)"})
		return
	}

	c.JSON(http.StatusOK, gin.H{"message": "File uploaded successfully", "filename": header.Filename})
}
func TestUploadHandler(t *testing.T) {
	gin.SetMode(gin.TestMode)
	router := gin.Default()
	router.POST("/upload", uploadHandler)

	t.Run("Successful Upload", func(t *testing.T) {
		req, writer := createMultipartRequest(t, "file", "test.txt", "This is a test file.")
		resp := httptest.NewRecorder()
		router.ServeHTTP(resp, req)

		assert.Equal(t, http.StatusOK, resp.Code)
		assert.Contains(t, resp.Body.String(), "File uploaded successfully")
		assert.Contains(t, resp.Body.String(), "test.txt")
		assert.Equal(t, writer.FormDataContentType(), req.Header.Get("Content-Type"))
	})

	t.Run("File Too Large", func(t *testing.T) {
		req, _ := createMultipartRequest(t, "file", "large.txt", strings.Repeat("A", 101*1024*1024)) // 101 MB
		resp := httptest.NewRecorder()
		router.ServeHTTP(resp, req)

		assert.Equal(t, http.StatusBadRequest, resp.Code)
		assert.Contains(t, resp.Body.String(), "File too large (max 100MB)")
	})

	t.Run("Missing File Field", func(t *testing.T) {
		req := httptest.NewRequest("POST", "/upload", nil)
		resp := httptest.NewRecorder()
		router.ServeHTTP(resp, req)

		assert.Equal(t, http.StatusBadRequest, resp.Code)
		assert.Contains(t, resp.Body.String(), "Failed to get file")
	})
}
func TestUploadHandler_InvalidContentType(t *testing.T) {
	gin.SetMode(gin.TestMode)
	router := gin.Default()
	router.POST("/upload", uploadHandler)

	// Create a request with an invalid content type
	req := httptest.NewRequest("POST", "/upload", strings.NewReader("This is not a file upload"))
	req.Header.Set("Content-Type", "text/plain")
	resp := httptest.NewRecorder()
	router.ServeHTTP(resp, req)

	assert.Equal(t, http.StatusBadRequest, resp.Code)
	assert.Contains(t, resp.Body.String(), "Failed to get file")
}

// test upload SanitizeFile

func TestUploadHandler_SanitizeFileName(t *testing.T) {
	gin.SetMode(gin.TestMode)
	router := gin.Default()
	router.POST("/upload", uploadHandler)

	// Create a request with a filename that needs sanitization
	req, writer := createMultipartRequest(t, "file", "test file.txt", "This is a test file.")
	resp := httptest.NewRecorder()
	router.ServeHTTP(resp, req)

	assert.Equal(t, http.StatusOK, resp.Code)
	assert.Contains(t, resp.Body.String(), "File uploaded successfully")
	assert.Contains(t, resp.Body.String(), "test_file.txt") // Check if the filename was sanitized
	assert.Equal(t, writer.FormDataContentType(), req.Header.Get("Content-Type"))
}
