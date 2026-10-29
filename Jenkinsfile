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
    withEnv([
        "IMAGE_REF=${imageRef}",
        "CANDIDATE_NAME=${candidateName}",
        "EXPECTED_ENV=${expectedEnv}"
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
    }

    post {
        success {
            echo 'All shell validation and test suites passed.'
        }
        failure {
            echo 'Validation or test failed. Review the stage logs.'
        }
    }
}
