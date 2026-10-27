# Jenkins Multi-Environment CI/CD

Reusable Jenkins Pipeline for a Docker-based web application.

## Environments

| Branch      | Environment | Host Port |
| ----------- | ----------- | --------: |
| development | Development |      8083 |
| staging     | Staging     |      8084 |
| production  | Production  |      8085 |

## Pipeline

1. Checkout source
2. Validate source
3. Build Docker image
4. Test Docker image
5. Request production approval
6. Deploy to the matching environment
7. Verify HTTP health check
8. Restore the previous container if deployment verification fails

## Requirements

- Jenkins Multibranch Pipeline
- GitHub repository and branch discovery
- Docker CLI available in Jenkins
- Access to the Docker host socket
- Available deployment ports

## Security

Access to `/var/run/docker.sock` effectively grants extensive control over the Docker host.
Restrict Jenkins access and credentials to trusted users and jobs.
