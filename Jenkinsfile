/* groovylint-disable CompileStatic */
/*
 * Reusable Jenkins CI/CD Pipeline
 * Environments: development, staging, production
 *
 * Requirements:
 * - Jenkins Multibranch Pipeline
 * - Docker CLI available inside Jenkins
 * - /var/run/docker.sock mounted
 */

void testDockerImage(String imageRef, String candidateName) {
    withEnv([
        "IMAGE_REF=${imageRef}",
        "CANDIDATE_NAME=${candidateName}"
    ]) {
        sh '''
            set -eu

            docker rm -f "$CANDIDATE_NAME" >/dev/null 2>&1 || true

            echo "Testing image: $IMAGE_REF"

            docker run -d \
                --name "$CANDIDATE_NAME" \
                "$IMAGE_REF" >/dev/null

            if docker exec "$CANDIDATE_NAME" \
                wget -q -O /dev/null http://127.0.0; then
                echo "IMAGE TEST PASSED"
            else
                docker logs "$CANDIDATE_NAME" || true
                docker rm -f "$CANDIDATE_NAME" >/dev/null 2>&1 || true
                echo "IMAGE TEST FAILED"
                exit 1
            fi

            docker rm -f "$CANDIDATE_NAME" >/dev/null
        '''
    }
}

void deployEnvironment(
    String targetContainer,
    String targetPort,
    String imageRef
) {
    String candidateName =
        "${targetContainer}-candidate-${env.BUILD_NUMBER}"

    String backupName =
        "${targetContainer}-previous-${env.BUILD_NUMBER}"

    // Test again immediately before deployment.
    testDockerImage(imageRef, candidateName)

    withEnv([
        "TARGET_CONTAINER=${targetContainer}",
        "TARGET_PORT=${targetPort}",
        "IMAGE_REF=${imageRef}",
        "BACKUP_NAME=${backupName}"
    ]) {
        sh '''
            set -eu

            # Never overwrite an existing backup.
            if docker inspect "$BACKUP_NAME" >/dev/null 2>&1; then
                echo "ERROR: Backup already exists: $BACKUP_NAME"
                exit 1
            fi

            HAD_OLD=false

            restore_previous() {
                if [ "$HAD_OLD" = "true" ]; then
                    echo "Restoring previous release..."

                    docker rename "$BACKUP_NAME" "$TARGET_CONTAINER"
                    docker update --restart=unless-stopped "$TARGET_CONTAINER"
                    docker start "$TARGET_CONTAINER"

                    echo "Previous release restored."
                fi
            }

            # Preserve the current release before replacing it.
            if docker inspect "$TARGET_CONTAINER" >/dev/null 2>&1; then
                docker update --restart=no "$TARGET_CONTAINER"
                docker stop "$TARGET_CONTAINER"
                docker rename "$TARGET_CONTAINER" "$BACKUP_NAME"

                HAD_OLD=true
                echo "Previous release saved as $BACKUP_NAME"
            else
                echo "No previous release exists."
            fi

            # Start the new release.
            if docker run -d \
                --name "$TARGET_CONTAINER" \
                --restart unless-stopped \
                -p "$TARGET_PORT:80" \
                "$IMAGE_REF"; then

                sleep 2

                if docker exec "$TARGET_CONTAINER" \
                    wget -q -O /dev/null http://127.0.0; then

                    echo "DEPLOYMENT VERIFIED"
                    echo "Container: $TARGET_CONTAINER"
                    echo "Image: $IMAGE_REF"
                    echo "Port: $TARGET_PORT"

                    # Keep the previous container as a backup.
                else
                    echo "ERROR: Health check failed."
                    docker logs "$TARGET_CONTAINER" || true
                    docker rm -f "$TARGET_CONTAINER" >/dev/null 2>&1 || true

                    restore_previous
                    exit 1
                fi
            else
                echo "ERROR: Failed to start new release."
                restore_previous
                exit 1
            fi
        '''
    }
}

pipeline {
    agent any

    options {
        skipDefaultCheckout(true)
        timestamps()
        disableConcurrentBuilds()
    }

    environment {
        APP_NAME = 'multienv-web'
        BRANCH_DEV = 'development'
        BRANCH_STG = 'staging'
        BRANCH_PROD = 'production'
    }

    stages {
        stage('1. Checkout') {
            steps {
                checkout scm

                script {
                    env.GIT_COMMIT_SHORT = sh(
                        script: 'git rev-parse --short=12 HEAD',
                        returnStdout: true
                    ).trim()

                    echo "Branch: ${env.BRANCH_NAME}"
                    echo "Commit: ${env.GIT_COMMIT_SHORT}"
                }
            }
        }

        stage('2. Validate Source') {
            steps {
                sh '''
                    set -eu

                    test -s src/index.html
                    test -s Dockerfile
                    test -s tests/healthcheck.sh

                    grep -qi '^FROM nginx:' Dockerfile

                    echo "Source validation passed."
                '''
            }
        }

        stage('3. Build Docker Image') {
            steps {
                script {
                    String imageRef =
                        "${env.APP_NAME}:${env.GIT_COMMIT_SHORT}"

                    sh """
                        set -eu
                        docker build -t '${imageRef}' .
                        docker image inspect '${imageRef}' >/dev/null
                    """

                    echo "Built image: ${imageRef}"
                }
            }
        }

        stage('4. Test Docker Image') {
            steps {
                script {
                    String imageRef =
                        "${env.APP_NAME}:${env.GIT_COMMIT_SHORT}"

                    String testContainer =
                        "${env.APP_NAME}-test-${env.BUILD_NUMBER}"

                    testDockerImage(imageRef, testContainer)
                }
            }
        }

        stage('5. Approve Production') {
            when {
                branch "${env.BRANCH_PROD}"
            }
            steps {
                input(
                    message: "Approve production deployment of ${env.APP_NAME}:${env.GIT_COMMIT_SHORT}?",
                    ok: 'Deploy to Production'
                )
            }
        }

        stage('6. Deploy Development') {
            when {
                branch "${env.BRANCH_DEV}"
            }
            steps {
                script {
                    deployEnvironment(
                        "${env.APP_NAME}-development",
                        '8083',
                        "${env.APP_NAME}:${env.GIT_COMMIT_SHORT}"
                    )
                }
            }
        }

        stage('7. Deploy Staging') {
            when {
                branch "${env.BRANCH_STG}"
            }
            steps {
                script {
                    deployEnvironment(
                        "${env.APP_NAME}-staging",
                        '8084',
                        "${env.APP_NAME}:${env.GIT_COMMIT_SHORT}"
                    )
                }
            }
        }

        stage('8. Deploy Production') {
            when {
                branch "${env.BRANCH_PROD}"
            }
            steps {
                script {
                    deployEnvironment(
                        "${env.APP_NAME}-production",
                        '8085',
                        "${env.APP_NAME}:${env.GIT_COMMIT_SHORT}"
                    )
                }
            }
        }
    }

    post {
        success {
            echo "Pipeline succeeded for branch ${env.BRANCH_NAME}."
        }

        failure {
            echo 'Pipeline failed. Review the stage logs before retrying.'
        }

        always {
            echo "Build ${env.BUILD_NUMBER} finished."
        }
    }
}
