// =============================================================================
// Initialization Script: Create the Seed Job
// =============================================================================
// This script runs once when Jenkins starts (via init.groovy.d/).
// It creates the "Seed-Job" which auto-generates project pipelines.
//
// Files in init.groovy.d/ execute in alphabetical order at startup.
// This ensures the seed job exists before anything else runs.
// =============================================================================

import jenkins.model.Jenkins
import javaposse.jobdsl.plugin.JobDSLProject
import com.cloudbees.plugins.credentials.CredentialsProvider
import org.jenkinsci.plugins.workflow.job.WorkflowJob
import org.jenkinsci.plugins.workflow.cps.CpsFlowDefinition

// ─── Get Jenkins instance ────────────────────────────────────────────────────
def jenkins = Jenkins.getInstance()
def seedJobName = "_Admin/Seed-Job"

println("=" * 70)
println("🌱 Initializing Seed Job...")
println("=" * 70)

// ─── Create _Admin folder if it doesn't exist ────────────────────────────────
def adminFolder = jenkins.items.find { it.name == "_Admin" }
if (!adminFolder) {
    println("📁 Creating _Admin folder...")
    def folderClass = jenkins.getPluginManager().uberClassLoader.loadClass("com.cloudbees.hudson.plugins.folder.Folder")
    adminFolder = folderClass.newInstance(jenkins, "_Admin")
    adminFolder.setDescription("🔧 Jenkins Administration — manage seed job, system config")
    jenkins.add(adminFolder, "_Admin")
    jenkins.save()
    println("✅ _Admin folder created")
} else {
    println("ℹ️  _Admin folder already exists")
}

// ─── Find or create Seed-Job ─────────────────────────────────────────────────
def seedJob = adminFolder.items.find { it.name == "Seed-Job" }

if (seedJob) {
    println("ℹ️  Seed-Job already exists")
} else {
    println("🌱 Creating Seed-Job...")

    // Read the seed job DSL from file
    def seedJobDslFile = new File("/var/jenkins-config/seed-job.groovy")
    if (!seedJobDslFile.exists()) {
        println("⚠️  Warning: seed-job.groovy not found at /var/jenkins-config/seed-job.groovy")
        println("    Seed job will be created but will not auto-generate projects.")
    }

    def seedJobDsl = seedJobDslFile.exists() ? seedJobDslFile.text : ""

    // Create a Job DSL job (uses job-dsl plugin)
    // The JobDSLProject class allows us to embed DSL directly
    def newSeedJob = new JobDSLProject(adminFolder, "Seed-Job")
    newSeedJob.setDescription("""
🌱 Seed Job — Auto-generates Jenkins pipelines

This job:
  1. Scans /var/projects/ for project folders
  2. Reads project.yaml from each project
  3. Auto-creates Deploy/Rollback/Health Check jobs
  4. Runs whenever projects are added/modified

Trigger manually: Click "Build Now"
Trigger automatically: Set up a webhook from your projects repo (optional)
""".stripIndent())

    // Create a CPS flow definition (declarative pipeline)
    def pipelineScript = """
        pipeline {
            agent any
            options {
                timestamps()
                timeout(time: 10, unit: 'MINUTES')
                buildDiscarder(logRotator(numToKeepStr: '20'))
            }
            stages {
                stage('Generate Jobs') {
                    steps {
                        jobDsl {
                            targets 'seed-job.groovy'
                            unstableOnWarning true
                            unstableOnDeprecatedDsl true
                            removedJobAction 'IGNORE'
                            removedViewAction 'IGNORE'
                            lookupStrategy 'JENKINS_ROOT'
                        }
                    }
                }
            }
            post {
                always {
                    echo "📋 Seed job execution complete"
                }
                success {
                    echo "✅ Projects discovered and configured"
                }
                failure {
                    echo "❌ Seed job failed — check the log above"
                }
            }
        }
    """.stripIndent()

    try {
        def definition = new CpsFlowDefinition(pipelineScript, true)
        newSeedJob.setDefinition(definition)
        adminFolder.add(newSeedJob, "Seed-Job")
        jenkins.save()
        println("✅ Seed-Job created successfully")
    } catch (Exception e) {
        println("❌ Failed to create Seed-Job: ${e.message}")
        e.printStackTrace()
    }
}

println("=" * 70)
println("✅ Seed Job initialization complete")
println("=" * 70)
println("")
println("Next steps:")
println("  1. Open Jenkins: http://localhost:8080")
println("  2. Go to: _Admin → Seed-Job → Build Now")
println("  3. Add your first project: ./add-project.sh --name myapp --host X.X.X.X --user deployuser")
println("")
