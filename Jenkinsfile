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
        "DEPLOYMENT_ID=${env.BUILD_TAG}-${targetContainer}"
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
                    test -s src/index.html.template
                    test -s deploy/10-render-template.sh
                    test -s Dockerfile
                    test -s tests/healthcheck.sh
                    grep -qi '^FROM nginx:' Dockerfile
                    test -s deploy/deploy-container.sh
                    test -s deploy/cleanup-backups.sh

                    sh -n deploy/10-render-template.sh
                    sh -n deploy/deploy-container.sh
                    sh -n deploy/cleanup-backups.sh
                    sh -n tests/healthcheck.sh
                    echo "Source validation passed."
                '''
            }
        }

        stage('3. Build Docker Image') {
            steps {
                script {
                    String imageRef =
                        "${env.APP_NAME}:${env.GIT_COMMIT_SHORT}"

                    String appEnv = env.BRANCH_NAME.toUpperCase()

                    sh """
                        set -eu
                        docker build --build-arg APP_ENV='${appEnv}' -t '${imageRef}' .
                        docker image inspect '${imageRef}' >/dev/null
                    """

                    echo "Built image: ${imageRef}"
                    echo "Application environment: ${appEnv}"
                }
            }
        }

        stage('4. Test Docker Image') {
            steps {
                script {
                    String imageRef =
                        "${env.APP_NAME}:${env.GIT_COMMIT_SHORT}"

                    String safeBranch = env.BRANCH_NAME.replaceAll(
                        '[^a-zA-Z0-9_.-]',
                        '-'
                    )

                    String testContainer =
                        "${env.APP_NAME}-test-${safeBranch}-${env.BUILD_NUMBER}"

                    String expectedEnv = env.BRANCH_NAME.toUpperCase()

                    testDockerImage(
                        imageRef,
                        testContainer,
                        expectedEnv
                    )
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
                        "${env.APP_NAME}:${env.GIT_COMMIT_SHORT}",
                        'DEVELOPMENT'
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
                        "${env.APP_NAME}:${env.GIT_COMMIT_SHORT}",
                        'STAGING'
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
                        "${env.APP_NAME}:${env.GIT_COMMIT_SHORT}",
                        'PRODUCTION'
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
