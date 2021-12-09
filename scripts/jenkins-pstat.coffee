# Description:
#   Interact with your Jenkins CI server
#
# Configuration:
#   HUBOT_JENKINS_URL
#   HUBOT_JENKINS_AUTH - Optional; for authenticating the trigger request (user:password)
#
# Commands:
#   hubot ci issue <issue_number> - builds the pstat_ticket job with the corresponding issue_<issue_number> branch
#   hubot ci workers <N> - Launch N number of jenkins workers. N is optional and defaults to 1. Use "max" to use the default maximum number of workers.

# GCLOUD_PROJECT is passed in automatically from the env
moment = require('moment')
sprintf = require('sprintf-js').sprintf

github = {}
gce = {}

CI_ENABLED = process.env.CI_ENABLED == 'true'

HUBOT_JENKINS_URL = process.env.HUBOT_JENKINS_URL
HUBOT_JENKINS_AUTH = process.env.HUBOT_JENKINS_AUTH
HUBOT_GITHUB_REPO = process.env.HUBOT_GITHUB_REPO

JENKINS_JNLP_CREDENTIALS = process.env.JENKINS_JNLP_CREDENTIALS
JENKINS_AGENT_LABEL = process.env.JENKINS_AGENT_LABEL
JENKINS_AGENT_AWS_ACCESS_KEY_ID = process.env.JENKINS_AGENT_AWS_ACCESS_KEY_ID
JENKINS_AGENT_AWS_SECRET_ACCESS_KEY = process.env.JENKINS_AGENT_AWS_SECRET_ACCESS_KEY

JENKINS_NOTIFICATION_ENDPOINT = process.env.JENKINS_NOTIFICATION_ENDPOINT or "/hubot/build-status"
JENKINS_ROOT_JOB_NOTIFICATION_ENDPOINT = process.env.JENKINS_ROOT_JOB_NOTIFICATION_ENDPOINT or "/hubot/root-build-status"
JENKINS_ROOT_JOB_NAME = process.env.JENKINS_ROOT_JOB_NAME or "pstat_ticket"

# These values can be obtained from the JSON key file you download when creating
# a service account.
# Required GCE configs
GCE_CREDENTIALS_CLIENT_EMAIL = process.env.GCE_CREDENTIALS_CLIENT_EMAIL
GCE_CREDENTIALS_PRIVATE_KEY = process.env.GCE_CREDENTIALS_PRIVATE_KEY
GCE_DISK_SOURCE_IMAGE = process.env.GCE_DISK_SOURCE_IMAGE
GCE_ZONE_NAMES = process.env.GCE_ZONE_NAMES.split(' ')
# Optional GCE configs
GCE_MACHINE_TYPE = process.env.GCE_MACHINE_TYPE or 'n1-highcpu-2'

GCE_COMPUTE_ENGINE_SERVICE_ACCOUNT_EMAIL = process.env.GCE_COMPUTE_ENGINE_SERVICE_ACCOUNT_EMAIL or ''
DISK_TYPE_TPL = 'zones/%s/diskTypes/pd-ssd'

BUILD_DATA = {
  'COMMIT_SHA': 'commit_SHA',
  'GIT_BRANCH': 'git_branch',
  'DOWNSTREAM_JOBS_COUNT': 'downstream_jobs_count',
  'MARKED_AS_FINISHED': 'marked_as_finished',
  'ROOT_JOB_NAME': 'root_job_name',
}
JENKINS_BUILD_STATUS = {
  'FAILURE': 'FAILURE',
  'SUCCESS': 'SUCCESS',
  'ABORTED': 'ABORTED',
}
JENKINS_BUILD_PHASE = {
  'COMPLETED': 'COMPLETED',
  'STARTED': 'STARTED',
}
GITHUB_REPO_STATUS = {
  'PENDING': 'pending',
  'FAILURE': 'failure',
  'SUCCESS': 'success',
}

launchJenkinsWorkers = (workerCount, forceLaunch) ->
  instances = []
  zoneResultsCount = 0

  console.log "Received request to launch #{workerCount} workers"

  _aggregateVMsAcrossZones = (err, vms) ->
    if err
      console.log 'Error retrieving current VM list'
      console.log err
      return
    zoneResultsCount += 1
    instances = instances.concat(vms)
    remaining = GCE_ZONE_NAMES.length - zoneResultsCount
    if remaining > 0
      console.log "VM list pending for #{remaining} more zone(s)"
    else
      console.log 'Finished building list of instances. Preparing to create workers'
      _createWorkers()
    return

  _createWorkers = () ->
    instanceCountByZone = _getInstanceCountByZone(instances)
    console.log 'instanceCountByZone', instanceCountByZone

    numRunningInstances = 0
    for zoneName of instanceCountByZone
      numRunningInstances += instanceCountByZone[zoneName]

    if forceLaunch isnt true and numRunningInstances >= workerCount
      console.log "The requested number of workers #{workerCount} are already running"
      return

    workerNumbersByZone = _distributeWorkersAcrossZones(workerCount, instanceCountByZone)
    timestamp = moment().format 'MMDD-HHmmss-SS'  # e.g. 0901-134102-09
    for zoneName of workerNumbersByZone
      _createWorkersInZone workerNumbersByZone[zoneName], zoneName, timestamp
    return

  for zoneName in GCE_ZONE_NAMES
    zone = gce.zone(zoneName)
    # Determine which zones are busy, based on which currently have VMs,
    # so that we can spread our workers across zones.
    # This minimizes the likelihood of all of our workers being prempted at the same time.
    zone.getVMs _aggregateVMsAcrossZones

  return

_getInstanceCountByZone = (instances) ->
  instanceCountByZone = {}
  for zoneName in GCE_ZONE_NAMES
    instanceCountByZone[zoneName] = 0

  for instance in instances
    # Only STAGING and RUNNING statuses indicate that there are available resources in a zone
    # see: https://cloud.google.com/compute/docs/instances/#checkmachinestatus
    status = instance.metadata.status
    if status in ['STAGING', 'RUNNING']
        instanceCountByZone[instance.zone.name] += 1
    else if status == 'TERMINATED'
      console.log "Deleting #{instance.name} with status #{status}"
      instance.delete()
    else
      console.log "Ignoring #{instance.name} with status #{status}"
  instanceCountByZone

_distributeWorkersAcrossZones = (workerCount, instanceCountByZone) ->
  maxWorkersPerZone = Math.ceil(workerCount / GCE_ZONE_NAMES.length)
  console.log "Placing a max of #{maxWorkersPerZone} workers in each zone"

  workerIndexes = [0...workerCount]

  # Distribute the indexes evenly across the zones.
  # The last zones will get 1 less if it doesn't work out evenly.
  # In the case of very low numbers (e.g. 5 nodes in 4 zones),
  # it's possible for zones to get no indexes.
  i = 0
  workerNumbersByZone = {}
  for zoneName of instanceCountByZone
    workerNumbersByZone[zoneName] = workerIndexes[i .. (i+maxWorkersPerZone)-1]
    console.log 'Zone', zoneName, 'will have workers:', workerNumbersByZone[zoneName]
    i += maxWorkersPerZone
  workerNumbersByZone

_createWorkersInZone = (workerIndexes, zoneName, timestamp) ->
  zone = gce.zone(zoneName)
  desiredMachineCount = workerIndexes.length
  vmConfig = {
    machineType: GCE_MACHINE_TYPE
    disks: [
      {
        boot: true
        initializeParams: {
          sourceImage: "global/images/#{ GCE_DISK_SOURCE_IMAGE }"
          diskType: 'zones/us-central1-a/diskTypes/pd-ssd'
        }
        autoDelete: true
      }
    ]
    networkInterfaces: [
      {
        network: 'global/networks/default'
        accessConfigs: [
          {
            type: 'ONE_TO_ONE_NAT'
            name: 'External NAT'
          }
        ]
      }
    ]
    scheduling: {
      onHostMaintenance: 'TERMINATE'
      automaticRestart: false
      preemptible: true
    }
    metadata: {
      items: [
        {
          key: "JENKINS_URL"
          value: HUBOT_JENKINS_URL
        },
        {
          key: "JENKINS_AGENT_LABEL"
          value: JENKINS_AGENT_LABEL
        },
        {
          key: "JNLP_CREDENTIALS"
          value: JENKINS_JNLP_CREDENTIALS
        },
        {
          key: "AWS_ACCESS_KEY_ID"
          value: JENKINS_AGENT_AWS_ACCESS_KEY_ID
        },
        {
          key: "AWS_SECRET_ACCESS_KEY"
          value: JENKINS_AGENT_AWS_SECRET_ACCESS_KEY
        },
      ]
    }
  }
  console.log "Launching #{desiredMachineCount} machines in zone #{zone.name}"
  # The diskType config must be zone-specific
  vmConfig.disks[0].initializeParams.diskType = sprintf(DISK_TYPE_TPL, zone.name)
  if GCE_COMPUTE_ENGINE_SERVICE_ACCOUNT_EMAIL.length > 0
    # We have a service account, so let's give the machine read/write compute access
    vmConfig['serviceAccounts'] = [ {
      'email': GCE_COMPUTE_ENGINE_SERVICE_ACCOUNT_EMAIL
      'scopes': [ 'https://www.googleapis.com/auth/compute' ]
    } ]
  i = 0
  while i < desiredMachineCount
    vmName = sprintf('worker-%s-%02d-%s', timestamp, workerIndexes[i], zoneName)
    console.log "Creating VM: #{vmName}"
    zone.createVM vmName, vmConfig, jenkinsWorkerCreationCallback
    i++
  return

jenkinsWorkerCreationCallback = (err, vm, operation, apiResponse) ->
  if err
    console.log 'Error creating VM'
    console.log err
    return
  console.log "VM creation call succeeded for: #{vm.name} with #{operation.name}"
  return

rootJobCompletedSuccessfully = (robot, gitBranch, jobName, number) ->
  console.log "rootJobCompletedSuccessfully #{gitBranch} #{jobName} #{number}"
  baseUrl = HUBOT_JENKINS_URL
  # We use the job base URL, instead of the URL for the specific run,
  # because we need access to the `downstreamProjects` to know
  # when all of the downstream jobs are actually finished
  url = "#{baseUrl}/job/#{jobName}/api/json?tree=url,downstreamProjects"
  req = robot.http(url)

  if HUBOT_JENKINS_AUTH
    auth = new Buffer(HUBOT_JENKINS_AUTH).toString('base64')
    req.headers Authorization: "Basic #{auth}"

  req.get() (err, res, body) ->
    if err
      console.log "Getting job info from #{url} failed with status: #{err}"
    else if res.statusCode == 200
      json = JSON.parse(body)
      numberOfDownstreamJobs = json.downstreamProjects.length

      console.log "Storing root build data for #{number}"
      buildData = robot.brain.get(number) or {}
      buildData[BUILD_DATA.GIT_BRANCH] = gitBranch
      buildData[BUILD_DATA.DOWNSTREAM_JOBS_COUNT] = numberOfDownstreamJobs
      buildData[BUILD_DATA.ROOT_JOB_NAME] = jobName
      robot.brain.set number, buildData
      launchJenkinsWorkers(numberOfDownstreamJobs)
    else
      console.log "Getting job info from #{url} failed with status: #{res.statusCode}"


updateGithubBranchStatus = (branchName, state, targetURL, description, commitSHA) ->
  console.log "Updating github branch #{branchName} at #{commitSHA} as #{state}"
  repo = github.qualified_repo HUBOT_GITHUB_REPO

  githubPostStatusUrl = "repos/#{repo}/statuses/#{commitSHA}"
  data = {
    state: state,
    target_url: targetURL,
    description: description,
  }
  github.post githubPostStatusUrl, data, (comment_obj) ->
    console.log "Github branch #{branchName} marked as #{state}."


markGithubBranchAsFinished = (gitBranch, gitRevision, rootBuildNumber, buildStatuses, rootJobName) ->
  console.log "markGithubBranchAsFinished #{rootBuildNumber}"

  downstreamJobsCount = Object.keys(buildStatuses).length

  failedJobNames = []
  allSucceeded = true
  for jobName, jobStatus of buildStatuses
    if jobStatus != JENKINS_BUILD_STATUS.SUCCESS
      allSucceeded = false
      failedJobNames.push(jobName)

  if not allSucceeded
    statusDescription = "Failed jobs: "
    for failedJobName in failedJobNames
      statusDescription += " #{failedJobName}"
  else
    statusDescription = "Build #{rootBuildNumber} succeeded! #{downstreamJobsCount} downstream projects completed successfully."

  targetURL = "#{HUBOT_JENKINS_URL}/job/#{rootJobName}/#{rootBuildNumber}"
  status = if allSucceeded then GITHUB_REPO_STATUS.SUCCESS else GITHUB_REPO_STATUS.FAILURE
  updateGithubBranchStatus(gitBranch, status, targetURL, statusDescription, gitRevision)


jenkinsBuildIssue = (robot, msg) ->
    baseUrl = HUBOT_JENKINS_URL
    issue = msg.match[1]
    branch = "issue_#{issue}"
    # Save the user's private room id so we can reply to it later on
    channelId = msg.message.rawMessage.channel
    console.log "channel ID is #{channelId}"

    url = "#{baseUrl}/job/#{JENKINS_ROOT_JOB_NAME}/buildWithParameters?GIT_BRANCH=#{branch}"
    req = msg.http(url)
    if HUBOT_JENKINS_AUTH
      auth = new Buffer(HUBOT_JENKINS_AUTH).toString('base64')
      req.headers Authorization: "Basic #{auth}"

    req.header('Content-Length', 0)
    req.post() (err, res, body) ->
        if err
          message = "Jenkins reported an error: #{err}"
        else if res.statusCode == 201
          message = "#{JENKINS_ROOT_JOB_NAME} #{branch}: Queued"
          robot.brain.set branch, channelId
        else
          message = "Jenkins responded with status code #{res.statusCode}"
        robot.messageRoom channelId, message


downstreamJobCompleted = (robot, jobName, rootBuildNumber, buildNumber, buildStatus, gitRevision, gitBranch) ->
  console.log "downstreamJobCompleted #{jobName} #{rootBuildNumber} #{buildStatus} #{gitRevision} #{gitBranch}"
  buildData = robot.brain.get(rootBuildNumber) or {}

  statusesKey = "#{rootBuildNumber}_statuses"
  buildStatuses = robot.brain.get(statusesKey) or {}
  buildStatuses[jobName] = buildStatus
  robot.brain.set statusesKey, buildStatuses

  numFinishedDownstreamJobs = Object.keys(buildStatuses).length
  console.log "Number of finished downstream builds from root build #{rootBuildNumber}: #{numFinishedDownstreamJobs}"

  rootJobName = buildData[BUILD_DATA.ROOT_JOB_NAME]

  if numFinishedDownstreamJobs is buildData[BUILD_DATA.DOWNSTREAM_JOBS_COUNT]
    markGithubBranchAsFinished(gitBranch, gitRevision, rootBuildNumber, buildStatuses, rootJobName)
    buildData[BUILD_DATA.MARKED_AS_FINISHED] = true
    robot.brain.set rootBuildNumber, buildData
  else
    if buildStatus is JENKINS_BUILD_STATUS.FAILURE
      # This job failed. Even though all of the downstream jobs aren't finished,
      # we can already mark the build as a failure.
      targetURL = "#{HUBOT_JENKINS_URL}/job/#{rootJobName}/#{rootBuildNumber}"
      description = "Build #{buildNumber} of #{jobName} failed"
      updateGithubBranchStatus(gitBranch, GITHUB_REPO_STATUS.FAILURE, targetURL, description, gitRevision)


jenkinsLaunchWorkers = (msg) ->
    workerCount = msg.match[1]
    if not workerCount
      workerCount = 1
    forceLaunch = true
    launchJenkinsWorkers(workerCount, forceLaunch)
    msg.send "Launching #{workerCount} Jenkins workers"


module.exports = (robot) ->
  github = require("githubot")(robot)
  gcloud = require('gcloud')
  gce = gcloud.compute(
    credentials:
      client_email: GCE_CREDENTIALS_CLIENT_EMAIL
      private_key: GCE_CREDENTIALS_PRIVATE_KEY
  )

  github.handleErrors (response) ->
    console.log "Oh noes! A github request returned #{response.statusCode}"
    console.log "and error message: #{response.error}"
    console.log "and body: #{response.body}"

  robot.respond /ci issue ([\d_]+)/i, (msg) ->
    if CI_ENABLED is false
      msg.send "CI system is currently disabled"
      return
    jenkinsBuildIssue(robot, msg)

  robot.respond /ci workers ?(\d+)?/i, (msg) ->
    if CI_ENABLED is false
      msg.send "CI system is currently disabled"
      return
    jenkinsLaunchWorkers(msg)

  robot.respond /message test/i, (msg) ->
    channelId = msg.message.rawMessage.channel
    robot.messageRoom channelId, "pong - channel ID is #{channelId}"

  robot.router.post JENKINS_NOTIFICATION_ENDPOINT, (req, res) ->
    console.log "Post received on #{JENKINS_NOTIFICATION_ENDPOINT}"
    data = req.body

    jobName = data.name
    build = data.build
    if not build
      console.log "No build argument given. Exiting."
      res.end "ok"
      return

    gitRevision = build.parameters.GIT_COMMIT
    gitBranch = build.parameters.GIT_BRANCH
    rootBuildNumber = build.parameters.ROOT_BUILD_NUMBER
    buildNumber = build.number
    buildPhase = build.phase
    buildStatus = build.status

    if buildPhase is JENKINS_BUILD_PHASE.COMPLETED
      downstreamJobCompleted(robot, jobName, rootBuildNumber, buildNumber, buildStatus, gitRevision, gitBranch)

    res.end "ok"

  robot.router.post JENKINS_ROOT_JOB_NOTIFICATION_ENDPOINT, (req, res) ->
    console.log "Post received on #{JENKINS_ROOT_JOB_NOTIFICATION_ENDPOINT}"
    data = req.body
    rootJobName = data.name

    build = data.build
    if not build
      console.log "No build argument given. Exiting."
      res.end "ok"
      return

    gitBranch = build.parameters.GIT_BRANCH
    if not gitBranch
      console.log "No gitBranch argument given. Exiting."
      res.end "ok"
      return

    rootBuildNumber = build.number
    if not rootBuildNumber
      console.log "No rootBuildNumber argument given. Exiting."
      res.end "ok"
      return

    fullUrl = build.full_url

    roomToPostMessagesTo = robot.brain.get gitBranch
    if not roomToPostMessagesTo
      roomToPostMessagesTo = process.env.HUBOT_SLACK_CHANNEL

    if build.phase is JENKINS_BUILD_PHASE.STARTED
      message = "#{rootJobName} #{gitBranch} #{rootBuildNumber}: Started (#{fullUrl})"
      robot.messageRoom roomToPostMessagesTo, message

    else if build.phase is JENKINS_BUILD_PHASE.COMPLETED and build.status is JENKINS_BUILD_STATUS.SUCCESS
      message = "#{rootJobName} #{gitBranch} #{rootBuildNumber}: Completed successfully"
      robot.messageRoom roomToPostMessagesTo, message
      rootJobCompletedSuccessfully(robot, gitBranch, rootJobName, rootBuildNumber)

    res.end "ok"
