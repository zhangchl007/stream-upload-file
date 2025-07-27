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
	"sync/atomic"
	"syscall"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/pires/go-proxyproto"
	"go.uber.org/zap"
	"go.uber.org/zap/zapcore"
)

const (
	healthzPath = "/healthz"
	readyzPath  = "/readyz"
	versionPath = "/version"
)

var (
	ready int32 // 0 = not ready, 1 = ready
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

	// Liveness probe: always returns 200 if process is running
	r.GET(healthzPath, func(c *gin.Context) {
		c.Status(http.StatusOK)
	})

	// Readiness probe: returns 200 only if ready to serve traffic
	r.GET(readyzPath, func(c *gin.Context) {
		if atomic.LoadInt32(&ready) == 1 {
			c.Status(http.StatusOK)
		} else {
			c.Status(http.StatusServiceUnavailable)
		}
	})

	// Version endpoint for debugging
	r.GET(versionPath, func(c *gin.Context) {
		c.JSON(http.StatusOK, gin.H{
			"version": "v1.0.0",
			"commit":  "unknown",
		})
	})

	// Create storage client
	storageClient, err := storage.NewAzureBlobClient()
	if err != nil {
		logger.Fatal("Failed to create Azure storage client", zap.Error(err))
	}

	// Create file handler with storage client
	fileHandler := filehandler.NewAzureFileHandler(storageClient)
	if fileHandler == nil {
		logger.Fatal("Failed to create file handler")
	}

	// Mark as ready after successful initialization
	atomic.StoreInt32(&ready, 1)
	logger.Info("Application initialized and ready to serve traffic")

	// Set up routes
	r.POST("/upload", fileHandler.UploadHandler(""))
	r.GET("/download/:filename", fileHandler.DownloadHandler(""))

	// Set up HTTP server with graceful shutdown
	srv := &http.Server{
		Addr:         ":8080",
		Handler:      r,
		ReadTimeout:  30 * time.Second,
		WriteTimeout: 30 * time.Second,
		IdleTimeout:  120 * time.Second,
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
	signal.Notify(quit, syscall.SIGINT, syscall.SIGTERM, syscall.SIGQUIT)
	<-quit

	logger.Info("Shutdown signal received, starting graceful shutdown...")

	// Mark as not ready to stop receiving new traffic
	atomic.StoreInt32(&ready, 0)

	// Give load balancer time to detect we're not ready
	logger.Info("Waiting for load balancer to detect readiness change...")
	time.Sleep(15 * time.Second)

	// Create context with timeout for shutdown (should be less than terminationGracePeriodSeconds)
	shutdownTimeout := 30 * time.Second
	ctx, cancel := context.WithTimeout(context.Background(), shutdownTimeout)
	defer cancel()

	logger.Info("Shutting down server...", zap.Duration("timeout", shutdownTimeout))
	if err := srv.Shutdown(ctx); err != nil {
		logger.Error("Server forced to shutdown", zap.Error(err))
	} else {
		logger.Info("Server shutdown completed gracefully")
	}
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
