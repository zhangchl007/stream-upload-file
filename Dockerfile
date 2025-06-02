# Start from the official Golang image for building
FROM golang:1.23 as builder

WORKDIR /app

# Copy go mod and sum files
COPY go.mod go.sum ./
RUN go mod download

# Copy the source code
COPY . .

# Build the Go app
RUN CGO_ENABLED=0 GOOS=linux go build -o stream-upload-file main.go

# Use a minimal image for running
FROM gcr.io/distroless/base-debian12

WORKDIR /app

COPY --from=builder /app/stream-upload-file .

EXPOSE 8080

ENTRYPOINT ["/app/stream-upload-file"]