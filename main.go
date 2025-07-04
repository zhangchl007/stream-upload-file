package main

import (
	"context"
	"log"
	"net"
	"net/http"
	"os"
	"os/signal"
	"stream-upload-file/pkg/filehandler"
	"stream-upload-file/pkg/storage"
	"syscall"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/pires/go-proxyproto"
	"go.uber.org/zap"
	"go.uber.org/zap/zapcore"
)

func main() {
	// Initialize zap logger
	logConfig := zap.NewProductionConfig()
	logConfig.EncoderConfig.TimeKey = "timestamp"
	logConfig.EncoderConfig.EncodeTime = zapcore.ISO8601TimeEncoder

	logger, err := logConfig.Build()
	if err != nil {
		log.Fatalf("Failed to initialize logger: %v", err)
	}
	defer logger.Sync()

	zap.ReplaceGlobals(logger)

	// Set up Gin with zap
	gin.SetMode(gin.ReleaseMode)
	r := gin.New()
	r.Use(gin.Recovery())
	r.Use(GinZapMiddleware(logger))

	// Add health check endpoint for Kubernetes probes
	r.GET("/healthz", func(c *gin.Context) {
		c.Status(200)
	})

	// Add readiness probe endpoint for Kubernetes
	r.GET("/readyz", func(c *gin.Context) {
		c.Status(200)
	})

	// create new storage client
	storageClient, err := storage.NewAzureBlobClient()
	if err != nil {
		logger.Fatal("Failed to create Azure storage client", zap.Error(err))
	}
	// Create file handler with storage client
	fileHandler := filehandler.NewAzureFileHandler(storageClient)
	// Check if the file handler was created successfully
	if fileHandler == nil {
		logger.Fatal("Failed to create file handler")
	}
	// Set up routes
	r.POST("/upload", fileHandler.UploadHandler(""))
	r.GET("/download/:filename", fileHandler.DownloadHandler(""))

	// Set up HTTP server with graceful shutdown
	srv := &http.Server{
		Addr:    ":8080",
		Handler: r,
	}

	// --- PROXY protocol support ---
	ln, err := net.Listen("tcp", srv.Addr)
	if err != nil {
		logger.Fatal("Failed to listen", zap.Error(err))
	}
	proxyListener := &proxyproto.Listener{Listener: ln}
	defer proxyListener.Close()
	// --- end PROXY protocol support ---

	// Start server in a goroutine
	go func() {
		logger.Info("Starting server on :8080 with PROXY protocol support")
		if err := srv.Serve(proxyListener); err != nil && err != http.ErrServerClosed {
			logger.Fatal("Server failed to start", zap.Error(err))
		}
	}()

	// Wait for interrupt signal to gracefully shut down the server
	quit := make(chan os.Signal, 1)
	signal.Notify(quit, syscall.SIGINT, syscall.SIGTERM)
	<-quit

	logger.Info("Shutting down server...")

	// Create context with timeout for shutdown
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	if err := srv.Shutdown(ctx); err != nil {
		logger.Fatal("Server forced to shutdown", zap.Error(err))
	}

	logger.Info("Server exited gracefully")
}

// GinZapMiddleware returns a gin middleware that logs requests using zap
func GinZapMiddleware(logger *zap.Logger) gin.HandlerFunc {
	return func(c *gin.Context) {
		start := time.Now()
		path := c.Request.URL.Path

		c.Next()

		latency := time.Since(start)
		status := c.Writer.Status()

		logger.Info("Request",
			zap.String("method", c.Request.Method),
			zap.String("path", path),
			zap.Int("status", status),
			zap.Duration("latency", latency),
			zap.String("client_ip", c.ClientIP()),
			zap.String("user_agent", c.Request.UserAgent()),
		)
	}
}
