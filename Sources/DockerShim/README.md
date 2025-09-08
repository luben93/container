# Docker Moby Server API Shim

This directory contains a Docker Moby API compatibility shim for the Apple Container runtime. The shim provides HTTP REST endpoints that are compatible with the Docker Engine API, allowing Docker client tools to interact with the Apple Container runtime.

## Features

The Docker shim implements the following Docker API v1.43 endpoints:

### Container Management
- `GET /containers/json` - List containers (supports `all` parameter for showing stopped containers)
- `POST /containers/create` - Create a new container from Docker JSON format
- `POST /containers/{id}/start` - Start a container
- `POST /containers/{id}/stop` - Stop a container (supports `t` parameter for timeout)
- `DELETE /containers/{id}` - Remove a container (supports `force` parameter)
- `GET /containers/{id}/logs` - Get container logs

### System Information  
- `GET /version` - Get API version information
- `GET /_ping` - Health check endpoint

## Usage

### Building the Shim

The shim is built as a standalone Swift package to avoid dependency conflicts:

```bash
# Build the Docker shim
swift build --target container-docker-shim
```

### Running the Shim

```bash
# Start the Docker API shim on default port 2375
swift run container-docker-shim

# Start on custom host/port with debug logging
swift run container-docker-shim --host 0.0.0.0 --port 8080 --debug
```

### Testing with Docker Client

Once the shim is running, you can use standard Docker commands:

```bash
# Set Docker host to point to the shim
export DOCKER_HOST=tcp://localhost:2375

# List containers
docker ps -a

# Create a container
docker create --name test-container alpine:latest echo "Hello World"

# Start the container
docker start test-container

# View logs
docker logs test-container

# Stop and remove
docker stop test-container
docker rm test-container
```

### Testing with curl

You can also test the API directly:

```bash
# Health check
curl http://localhost:2375/_ping

# Get version info
curl http://localhost:2375/version

# List containers
curl http://localhost:2375/containers/json

# Create a container
curl -X POST \
  -H "Content-Type: application/json" \
  -d '{"Image":"alpine:latest","Cmd":["echo","hello"],"name":"test"}' \
  http://localhost:2375/containers/create?name=test
```

## Architecture

The shim consists of several key components:

- **DockerShim.swift**: Main entry point and command-line interface
- **DockerAPIServer.swift**: HTTP server using SwiftNIO with request routing
- **DockerAPIHandlers.swift**: Docker API endpoint implementations  
- **ContainerClientInterface.swift**: Abstraction layer and mock implementation

The shim translates Docker API requests to the internal container management system, handling:

- Docker JSON format conversion to ContainerConfiguration
- Container lifecycle state mapping
- Port publishing and networking configuration
- Environment variable handling
- Error handling and HTTP status codes

## Limitations

This is a compatibility shim with the following limitations:

- Currently uses a mock container backend for testing
- Limited to core container lifecycle operations
- No image management endpoints yet implemented
- Network and volume management endpoints are placeholders
- No authentication or TLS support

## Future Enhancements

Potential improvements include:

- Integration with actual Apple Container runtime via XPC
- Complete Docker API coverage (images, networks, volumes)
- Authentication and security features  
- Streaming log support
- Docker Compose compatibility
- Container stats and monitoring endpoints