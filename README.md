# Stream Upload File Service

A robust Go service for streaming file uploads and downloads to Azure Blob Storage, designed for cloud-native environments with Kubernetes deployment and Python-based load testing utilities.

---

## Features

- **Streamed file upload** to Azure Blob Storage (supports large files, up to 100MB per request)
- **File download** endpoint with streaming
- **Kubernetes-ready**: health/readiness probes, graceful shutdown, resource limits, and ingress examples
- **Azure Workload Identity** support for secure authentication
- **Structured logging** with Zap
- **Python scripts** for load and stress testing uploads

---

## Project Structure

```
.
├── Dockerfile
├── go.mod
├── go.sum
├── main.go
├── README.md
├── pkg/
│   ├── filehandler/
│   │   ├── Filehandler.go
│   │   ├── download.go
│   │   ├── download_test.go
│   │   ├── upload.go
│   │   ├── upload_test.go
│   │   └── Filehander_test.go
│   └── storage/
│       ├── azureblob.go
│       └── azureblob_test.go
└── deploy/
    ├── appgateway-ingress.yaml
    ├── deploy-app.yaml
    ├── deploy-app-k8s.yaml
    ├── ingress-deploy.yaml
    ├── one-uploadfile.py
    ├── uploadfile.py
    └── README.md
```

---

## Quick Start

### 1. Build and Run Locally

```sh
go build -o stream-upload-file main.go
STORAGE_ACCOUNT_NAME=<your-account> STORAGE_CONTAINER_NAME=<your-container> ./stream-upload-file
```

### 2. Build and Push Docker Image

```sh
docker build -t <your-repo>/stream-upload-file:latest .
docker push <your-repo>/stream-upload-file:latest
```

### 3. Deploy to Kubernetes

- Edit `deploy/deploy-app.yaml` or `deploy/deploy-app-k8s.yaml` to set your storage account/container and image.
- Deploy:

```sh
kubectl apply -f deploy/deploy-app.yaml
kubectl apply -f deploy/ingress-deploy.yaml
```

- For Azure Application Gateway Ingress, use `deploy/appgateway-ingress.yaml`.

### 4. Test Uploads

- Use the provided Python scripts in `deploy/`:

```sh
pip install requests
python deploy/one-uploadfile.py --url http://localhost:8080/upload --file deploy/test1.zip
python deploy/uploadfile.py --url http://localhost:8080/upload --files deploy/test1.zip deploy/test2.zip
```

---

## API Endpoints

- `POST /upload`  
  Upload a file (multipart/form-data, field name: `file`)
- `GET /download/:filename`  
  Download a file by name
- `GET /healthz`  
  Liveness probe
- `GET /readyz`  
  Readiness probe

---

## Azure Authentication

- Uses [Azure Workload Identity](https://azure.github.io/azure-workload-identity/docs/) by default in Kubernetes.
- Falls back to [DefaultAzureCredential](https://pkg.go.dev/github.com/Azure/azure-sdk-for-go/sdk/azidentity#DefaultAzureCredential) for local/dev.

**Required environment variables:**

- `STORAGE_ACCOUNT_NAME` – Azure Storage account name
- `STORAGE_CONTAINER_NAME` – Azure Blob container name
- (For workload identity) `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_FEDERATED_TOKEN_FILE`

---

## Kubernetes Notes

- The deployment uses a `ServiceAccount` for Azure Workload Identity.
- Ingress manifests are provided for both NGINX and Azure Application Gateway.
- Health and readiness probes are configured for robust rolling updates.
- Resource requests and limits are set for production readiness.

---

## Python Load Testing

See [`deploy/README.md`](deploy/README.md) for details on the Python upload scripts.

---

## Logging

- Uses [Uber Zap](https://github.com/uber-go/zap) for structured logging.
- Logs request details, upload/download attempts, and errors.

---

## License

MIT License

---

## Author

[Your Name or Organization]