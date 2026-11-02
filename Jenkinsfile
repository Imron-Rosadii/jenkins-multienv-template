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

void testDockerImage(
    String imageRef,
    String candidateName,
    String expectedEnv
) {
    String imageExpectedEnv = expectedEnv.toUpperCase()

    withEnv([
        "IMAGE_REF=${imageRef}",
        "CANDIDATE_NAME=${candidateName}",
        "EXPECTED_ENV=${imageExpectedEnv}"
    ]) {
        sh '''
            set -eu

            cleanup() {
                docker rm -f "$CANDIDATE_NAME" >/dev/null 2>&1 || true
            }

            cleanup
            trap cleanup EXIT

            echo "Testing image: $IMAGE_REF"
            echo "Expected environment: $EXPECTED_ENV"

            docker run -d \
                --name "$CANDIDATE_NAME" \
                "$IMAGE_REF" >/dev/null
            OK=0

            for i in $(seq 1 15); do
                if docker exec "$CANDIDATE_NAME" \
                    wget -q -O /dev/null http://127.0.0.1/; then
                    OK=1
                    break
                fi

                sleep 2
            done

            if [ "$OK" -ne 1 ]; then
                echo "ERROR: HTTP health check failed."
                docker logs "$CANDIDATE_NAME" || true
                exit 1
            fi

            HTML=$(docker exec "$CANDIDATE_NAME" \
                wget -q -O - http://127.0.0.1/)

            if ! printf '%s\n' "$HTML" |
                grep -Fq "Environment: $EXPECTED_ENV"; then
                echo "ERROR: Deployed environment content mismatch."
                echo "Expected: Environment: $EXPECTED_ENV"
                printf '%s\n' "$HTML"
                exit 1
            fi

            echo "IMAGE TEST PASSED"
            echo "Environment content check PASSED"
        '''
    }
}

void deployEnvironment(
    String targetContainer,
    String targetPort,
    String imageRef,
    String expectedEnv
) {
    String candidateName =
        "${targetContainer}-candidate-${env.BUILD_NUMBER}"

    String backupName =
        "${targetContainer}-previous-${env.BUILD_NUMBER}"

    // Test image before touching the current release.
    testDockerImage(imageRef, candidateName, expectedEnv)

    withEnv([
        "TARGET_CONTAINER=${targetContainer}",
        "TARGET_PORT=${targetPort}",
        "IMAGE_REF=${imageRef}",
        "BACKUP_NAME=${backupName}",
        "EXPECTED_ENV=${expectedEnv}",
        "DEPLOYMENT_ID=${env.BUILD_TAG}-${targetContainer}",
        'CLEANUP_MODE=dry-run'
    ]) {
        sh '''
            set -eu

            flock -x /var/jenkins_home/deployment.lock sh -c '
                set -eu
                sh deploy/deploy-container.sh

                if ! sh deploy/cleanup-backups.sh; then
                    echo "WARNING: Backup cleanup failed; deployment remains successful."
                fi
            '
        '''
    }
}

void resolveEnvironment() {
    String branchName = env.BRANCH_NAME ?: ''

    String commitShort = sh(
        script: 'git rev-parse --short=12 HEAD',
        returnStdout: true
    ).trim()

    echo "Detected branch: ${branchName}"
    echo "Commit: ${commitShort}"

    switch (branchName) {
        case 'development':
            env.APP_ENV = 'DEVELOPMENT'
            env.EXPECTED_ENV = 'Development'
            env.IMAGE_TAG = "development-${commitShort}"
            break

        case 'staging':
            env.APP_ENV = 'STAGING'
            env.EXPECTED_ENV = 'Staging'
            env.IMAGE_TAG = "staging-${commitShort}"
            break

        case 'production':
            env.APP_ENV = 'PRODUCTION'
            env.EXPECTED_ENV = 'Production'
            env.IMAGE_TAG = "production-${commitShort}"
            break

        default:
            env.APP_ENV = ''
            env.EXPECTED_ENV = ''
            env.IMAGE_TAG = ''

            echo "Branch '${branchName}' is CI-only."
            break
    }

    // Determine whether this branch is allowed to build an image.
    env.DEPLOY_ENV_ENABLED = env.APP_ENV ? 'true' : 'false'

    if (env.DEPLOY_ENV_ENABLED?.toBoolean()) {
        env.IMAGE_REF = "multienv-web:${env.IMAGE_TAG}"

        echo "Resolved APP_ENV: ${env.APP_ENV}"
        echo "Resolved EXPECTED_ENV: ${env.EXPECTED_ENV}"
        echo "Resolved IMAGE_REF: ${env.IMAGE_REF}"
    } else {
        env.IMAGE_REF = ''
        echo 'Docker build will be skipped.'
    }
}

pipeline {
    agent any

    options {
        skipDefaultCheckout(true)
        timestamps()
        disableConcurrentBuilds()
    }

    stages {
        stage('1. Checkout') {
            steps {
                checkout scm
            }
        }

        stage('2. Validate Shell Scripts') {
            steps {
                sh '''
                    set -eu

                    test -s deploy/cleanup-backups.sh
                    test -s deploy/deploy-container.sh
                    test -s tests/test-cleanup-backups.sh
                    test -s tests/test-deploy-container.sh

                    sh -n deploy/cleanup-backups.sh
                    sh -n deploy/deploy-container.sh
                    bash -n tests/test-cleanup-backups.sh
                    bash -n tests/test-deploy-container.sh

                    echo "Shell syntax validation passed."
                '''
            }
        }

        stage('3. Test Backup Cleanup Safely') {
            steps {
                sh '''
                    set -eu
                    bash tests/test-cleanup-backups.sh
                '''
            }
        }

        stage('4. Test Deployment and Rollback') {
            steps {
                sh '''
                    set -eu
                    bash tests/test-deploy-container.sh
                '''
            }
        }

        stage('5. Resolve Environment') {
            steps {
                script {
                    resolveEnvironment()
                }
            }
        }

        stage('6. Build Docker Image') {
            when {
                expression {
                    env.DEPLOY_ENV_ENABLED?.toBoolean()
                }
            }
            steps {
                script {
                    echo "Building Docker image: ${env.IMAGE_REF}"

                    sh '''
                        set -eu

                        docker build \
                            --build-arg APP_ENV="$APP_ENV" \
                            -t "$IMAGE_REF" \
                            .

                        echo "Docker image build completed."
                        docker image inspect "$IMAGE_REF" \
                            --format 'Image ID={{.Id}}'
                    '''
                }
            }
        }
        stage('7. Test Docker Image') {
            when {
                expression {
                    env.DEPLOY_ENV_ENABLED?.toBoolean()
                }
            }

            steps {
                script {
                    String candidateName =
                        "multienv-candidate-${env.BUILD_NUMBER}"

                    echo "Testing Docker image: ${env.IMAGE_REF}"
                    echo "Expected environment: ${env.EXPECTED_ENV}"

                    testDockerImage(
                        env.IMAGE_REF,
                        candidateName,
                        env.EXPECTED_ENV
                    )
                }
            }
        }
    }

    post {
        success {
            echo 'All validation, shell tests, Docker build, and image tests passed.'
        }
        failure {
            echo 'Validation or test failed. Review the stage logs.'
        }
}
}
