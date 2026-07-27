// =============================================================================
// Jenkins Seed Job — Auto-generate project pipelines
// =============================================================================
// This Job DSL script runs automatically and creates a Jenkins job for each
// project folder found in /var/projects/
//
// What it does:
//   1. Scans /var/projects/ for project folders
//   2. Reads project.yaml from each folder
//   3. Auto-creates a Jenkins Multibranch Pipeline job
//   4. Wires up credentials, playbooks, and inventory
//
// Reference: https://plugins.jenkins.io/job-dsl/
// =============================================================================

import java.nio.file.Files
import java.nio.file.Paths
import java.nio.file.DirectoryStream
import groovy.yaml.YamlSlurper

def projectsDir = new File('/var/projects')
def projects = []

// ─── Scan for projects ───────────────────────────────────────────────────────
if (projectsDir.exists()) {
    projectsDir.eachDir { dir ->
        // Skip the template directory
        if (dir.name == '_template') {
            return
        }

        def projectYaml = new File(dir, 'project.yaml')
        if (projectYaml.exists()) {
            try {
                def config = new YamlSlurper().parse(projectYaml)
                projects.add(config)
                println("✅ Found project: ${config.name}")
            } catch (Exception e) {
                println("⚠️  Failed to parse ${dir.name}/project.yaml: ${e.message}")
            }
        }
    }
}

if (projects.size() == 0) {
    println("ℹ️  No projects found in /var/projects/")
    println("    Add a project: ./add-project.sh --name myapp --host X.X.X.X --user deployuser")
}

// ─── Create Jenkins jobs for each project ────────────────────────────────────
projects.each { project ->
    def name = project.name
    def displayName = project.display_name ?: name
    def credentialId = project.ssh_credential_id ?: "${name}-ssh-key"
    def inventoryFile = "/var/projects/${name}/inventory/hosts.ini"
    def playbookDir = "/var/projects/${name}/playbooks"

    println("🔨 Creating pipeline for: ${name}")

    // Create a folder for the project
    folder(name) {
        displayName(displayName)
        description(project.description ?: "Deployment pipeline for ${name}")
    }

    // Create Deploy job
    pipelineJob("${name}/Deploy") {
        displayName("Deploy")
        description("Deploy ${displayName}")

        definition {
            cps {
                script("""
                    @Library('shared-pipeline') _

                    pipeline {
                        agent any

                        options {
                            timeout(time: 30, unit: 'MINUTES')
                            buildDiscarder(logRotator(numToKeepStr: '10'))
                            ansiColor('xterm')
                        }

                        environment {
                            ANSIBLE_HOST_KEY_CHECKING = 'False'
                            ANSIBLE_INVENTORY = '${inventoryFile}'
                        }

                        stages {
                            stage('Validate') {
                                steps {
                                    script {
                                        echo "✅ Validating playbooks..."
                                        sh '''
                                            ansible-playbook --syntax-check ${playbookDir}/deploy.yml
                                            ansible --version
                                        '''
                                    }
                                }
                            }

                            stage('Deploy') {
                                steps {
                                    script {
                                        echo "🚀 Deploying ${displayName}..."
                                        sh '''
                                            ansible-playbook \\
                                                -i ${ANSIBLE_INVENTORY} \\
                                                -u ${ANSIBLE_USER:-ansible} \\
                                                --private-key=/var/ssh-keys/${name}.pem \\
                                                ${playbookDir}/deploy.yml \\
                                                -v
                                        '''
                                    }
                                }
                            }

                            stage('Health Check') {
                                when {
                                    expression { fileExists('${playbookDir}/healthcheck.yml') }
                                }
                                steps {
                                    script {
                                        echo "🏥 Running health checks..."
                                        sh '''
                                            ansible-playbook \\
                                                -i ${ANSIBLE_INVENTORY} \\
                                                -u ${ANSIBLE_USER:-ansible} \\
                                                --private-key=/var/ssh-keys/${name}.pem \\
                                                ${playbookDir}/healthcheck.yml
                                        '''
                                    }
                                }
                            }
                        }

                        post {
                            always {
                                echo "📋 Deployment complete"
                            }
                            failure {
                                echo "❌ Deployment failed"
                            }
                            success {
                                echo "✅ Deployment succeeded"
                            }
                        }
                    }
                """.stripIndent())
                sandbox(true)
            }
        }
    }

    // Create Rollback job
    pipelineJob("${name}/Rollback") {
        displayName("Rollback")
        description("Rollback ${displayName} to previous version")

        definition {
            cps {
                script("""
                    @Library('shared-pipeline') _

                    pipeline {
                        agent any

                        options {
                            timeout(time: 30, unit: 'MINUTES')
                            buildDiscarder(logRotator(numToKeepStr: '10'))
                            ansiColor('xterm')
                        }

                        environment {
                            ANSIBLE_HOST_KEY_CHECKING = 'False'
                            ANSIBLE_INVENTORY = '${inventoryFile}'
                        }

                        stages {
                            stage('Rollback') {
                                steps {
                                    script {
                                        echo "⏮️  Rolling back ${displayName}..."
                                        sh '''
                                            if [ -f ${playbookDir}/rollback.yml ]; then
                                                ansible-playbook \\
                                                    -i ${ANSIBLE_INVENTORY} \\
                                                    -u ${ANSIBLE_USER:-ansible} \\
                                                    --private-key=/var/ssh-keys/${name}.pem \\
                                                    ${playbookDir}/rollback.yml \\
                                                    -v
                                            else
                                                echo "⚠️  No rollback.yml found"
                                                exit 1
                                            fi
                                        '''
                                    }
                                }
                            }

                            stage('Verify') {
                                when {
                                    expression { fileExists('${playbookDir}/healthcheck.yml') }
                                }
                                steps {
                                    script {
                                        echo "🏥 Verifying rollback..."
                                        sh '''
                                            ansible-playbook \\
                                                -i ${ANSIBLE_INVENTORY} \\
                                                -u ${ANSIBLE_USER:-ansible} \\
                                                --private-key=/var/ssh-keys/${name}.pem \\
                                                ${playbookDir}/healthcheck.yml
                                        '''
                                    }
                                }
                            }
                        }

                        post {
                            always {
                                echo "📋 Rollback complete"
                            }
                            failure {
                                echo "❌ Rollback failed — manual intervention needed"
                            }
                            success {
                                echo "✅ Rollback succeeded"
                            }
                        }
                    }
                """.stripIndent())
                sandbox(true)
            }
        }
    }

    println("✅ Jobs created for: ${name}")
}

println("🎉 Seed job complete — ${projects.size()} project(s) configured")
