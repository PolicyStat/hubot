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
gcloud = require('gcloud')
moment = require('moment')
sprintf = require('sprintf-js').sprintf

github = {}

HUBOT_JENKINS_URL = process.env.HUBOT_JENKINS_URL
HUBOT_JENKINS_AUTH = process.env.HUBOT_JENKINS_AUTH
HUBOT_JENKINS_URL = process.env.HUBOT_JENKINS_URL
HUBOT_GITHUB_REPO = process.env.HUBOT_GITHUB_REPO

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
GCE_MACHINE_COUNT = parseInt(process.env.GCE_MACHINE_COUNT, 10) or 1

GCE_COMPUTE_ENGINE_SERVICE_ACCOUNT_EMAIL = process.env.GCE_COMPUTE_ENGINE_SERVICE_ACCOUNT_EMAIL or ''
DISK_TYPE_TPL = 'zones/%s/diskTypes/pd-ssd'

BUILD_DATA = {
  'COMMIT_SHA': 'commit_SHA',
  'ISSUE_NUMBER': 'issue_number',
  'DOWNSTREAM_JOBS_COUNT': 'downstream_jobs_count'
  'MARKED_AS_FINISHED': 'marked_as_finished'
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

gce = gcloud.compute(
  credentials:
    client_email: GCE_CREDENTIALS_CLIENT_EMAIL
    private_key: GCE_CREDENTIALS_PRIVATE_KEY
)

launchJenkinsWorkers = (workerCount) ->
  instances = []
  zoneResultsCount = 0

  _aggregateVMsAcrossZones = (err, vms) ->
    if err
      console.log 'Error retrieving current VM list'
      console.log err
      return
    zoneResultsCount += 1
    instances = instances.concat(vms)
    remaining = GCE_ZONE_NAMES.length - zoneResultsCount
    if remaining > 0
      console.log 'VM list pending for %s more zone(s)', remaining
    else
      console.log 'Finished building list of instances. Preparing to create workers'
      _createWorkers
    return

  _createWorkers = () ->
    instanceCountByZone = _getInstanceCountByZone(instances)
    console.log 'instanceCountByZone', instanceCountByZone

    numRunningInstances = 0
    for zoneName of instanceCountByZone
      numRunningInstances += instanceCountByZone[zoneName]

    if numRunningInstances >= workerCount
      console.log 'The requested number of workers %s are already running', workerCount
      return

    workerNumbersByZone = _distributeWorkersAcrossZones(workerCount, instanceCountByZone)
    timestamp = moment().format 'MMDD-HHmmss-SS'  # e.g. 0901-134102-09
    for zoneName of workerNumbersByZone
      _createWorkersInZone workerNumbersByZone[zoneName], zoneName, timestamp

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
      console.log 'Deleting', instance.name, 'with status', status
      instance.delete()
    else
      console.log 'Ignoring', instance.name, 'with status', status
    i++
  instanceCountByZone

_distributeWorkersAcrossZones = (workerCount, instanceCountByZone) ->
  maxWorkersPerZone = Math.ceil(workerCount / GCE_ZONE_NAMES.length)
  console.log 'Placing a max of %s workers in each zone', maxWorkersPerZone

  workerIndexes = [0...workerCount]

  # Distribute the indexes evenly across the zones.
  # The last zones will get 1 less if it doesn't work out evenly.
  # In the case of very low numbers (e.g. 5 nodes in 4 zones),
  # it's possible for zones to get no indexes.
  i = 0
  workerNumbersByZone = {}
  for zoneName of instanceCountByZone
    workerNumbersByZone[zoneName] = workerIndexes[i .. i + maxWorkersPerZone]
    console.log 'Zone', zoneName, 'will have workers:', instanceCountByZone[zoneName]
    i += maxWorkersPerZone
  workerNumbersByZone

_createWorkersInZone = (workerIndexes, zoneName, timestamp) ->
  zone = gce.zone(zoneName)
  desiredMachineCount = workerIndexes.length
  vmConfig =
    machineType: GCE_MACHINE_TYPE
    disks: [ {
      boot: true
      'initializeParams':
        'sourceImage': "global/images/#{ GCE_DISK_SOURCE_IMAGE }"
        'diskType': 'zones/us-central1-a/diskTypes/pd-ssd'
      'autoDelete': true
    } ]
    networkInterfaces: [ {
      network: 'global/networks/default'
      accessConfigs: [ {
        type: 'ONE_TO_ONE_NAT'
        name: 'External NAT'
      } ]
    } ]
    'scheduling':
      'onHostMaintenance': 'TERMINATE'
      'automaticRestart': false
      'preemptible': true
  console.log 'Launching %s machines in zone %s', desiredMachineCount, zone.name
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
    vmName = sprintf('worker-%s-%02d-zone-%s', timestamp, workerIndexes[i], zoneLetter)
    console.log 'Creating VM: %s', vmName
    zone.createVM vmName, vmConfig, jenkinsWorkerCreationCallback
    i++
  return

jenkinsWorkerCreationCallback = (err, vm, operation, apiResponse) ->
  if err
    console.log 'Error creating VM'
    console.log err
    return
  console.log 'VM creation call succeeded for: %s with %s', vm.name, operation.name
  return

jenkinsBuild = (msg) ->
    url = HUBOT_JENKINS_URL
    job = msg.match[1]

    path = "#{url}/job/#{job}/build"

    req = msg.http(path)

    if HUBOT_JENKINS_AUTH
      auth = new Buffer(HUBOT_JENKINS_AUTH).toString('base64')
      req.headers Authorization: "Basic #{auth}"

    req.header('Content-Length', 0)
    req.post() (err, res, body) ->
        if err
          msg.send "Jenkins says: #{err}"
        else if res.statusCode == 302
          msg.send "Build started for #{job} #{res.headers.location}"
        else
          msg.send "Jenkins says: #{body}"


registerRootJobStarted = (robot, jobUrl, issue, jobName, number, roomToPostMessagesTo) ->
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
      errorMessage = "Getting job info from #{url} failed with status: #{err}"
      console.log errorMessage
      robot.messageRoom roomToPostMessagesTo, errorMessage
    else if res.statusCode == 200
      json = JSON.parse(body)
      numberOfDownstreamJobs = json.downstreamProjects.length
      storeRootBuildData(robot, number, numberOfDownstreamJobs, issue)
    else
      message = "Getting job info from #{jobUrl} failed with status: #{res.statusCode}"
      robot.messageRoom roomToPostMessagesTo, message


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


markGithubBranchAsFinished = (rootBuildNumber, buildData, buildStatuses) ->
  console.log "markGithubBranchAsFinished #{rootBuildNumber}"
  issueNumber = buildData[BUILD_DATA.ISSUE_NUMBER]

  downstreamJobsCount = Object.keys(buildStatuses).length

  failedJobNames = []
  allSucceeded = true
  for jobName, jobStatus of buildStatuses
    if jobStatus != JENKINS_BUILD_STATUS.SUCCESS
      allSucceeded = false
      failedJobNames.push(jobName)

  if not allSucceeded
    statusDescription = "The following downstream projects failed: "
    for failedJobName in failedJobNames
      statusDescription += " #{failedJobName}"
  else
    statusDescription = "Build #{rootBuildNumber} succeeded! #{downstreamJobsCount} downstream projects completed successfully."

  targetURL = "#{HUBOT_JENKINS_URL}/job/#{JENKINS_ROOT_JOB_NAME}/#{rootBuildNumber}"
  updateGithubBranchStatus(
    "issue_#{issueNumber}",
    if allSucceeded then GITHUB_REPO_STATUS.SUCCESS else GITHUB_REPO_STATUS.FAILURE,
    targetURL,
    statusDescription,
    buildData[BUILD_DATA.COMMIT_SHA],
  )


jenkinsBuildIssue = (robot, msg) ->
    baseUrl = HUBOT_JENKINS_URL
    issue = msg.match[1]
    # Save the user's private room id so we can reply to it later on
    channelId = msg.message.rawMessage.channel
    console.log "channel ID is #{channelId}"
    jobName = JENKINS_ROOT_JOB_NAME

    # Start the workers early, so they're ready ASAP
    launchJenkinsWorkers(GCE_MACHINE_COUNT)

    url = "#{baseUrl}/job/#{jobName}/buildWithParameters?ISSUE=#{issue}"

    req = msg.http(url)
    if HUBOT_JENKINS_AUTH
      auth = new Buffer(HUBOT_JENKINS_AUTH).toString('base64')
      req.headers Authorization: "Basic #{auth}"

    req.header('Content-Length', 0)
    req.post() (err, res, body) ->
        if err
          message = "Jenkins reported an error: #{err}"
        else if res.statusCode == 201
          message = "Issue #{issue} has been queued"
          robot.brain.set issue, channelId
        else
          message = "Jenkins responded with status code #{res.statusCode}"
        robot.messageRoom channelId, message


storeRootBuildData = (robot, rootBuildNumber, numberOfDownstreamJobs, issueNumber) ->
  console.log "Storing root build data for #{rootBuildNumber}"
  # Store the number of downstream jobs and issue number
  buildData = robot.brain.get(rootBuildNumber) or {}

  buildData[BUILD_DATA.ISSUE_NUMBER] = issueNumber
  buildData[BUILD_DATA.DOWNSTREAM_JOBS_COUNT] = numberOfDownstreamJobs
  robot.brain.set rootBuildNumber, buildData


getAndStoreRootBuildCommit = (robot, jobName, rootBuildNumber, fullUrl, issue, roomToPostMessagesTo) ->
  # We need to get the SHA for this set of builds one time, after it completes,
  # and associate it with the build number in Hubot's persistent "brain"
  # storage. After that, we tie all of the actions for that build to the same
  # SHA. This lets us run multiple simultaneous builds against a branch for
  # different commits. It also ensures that if we add commits after a build
  # starts, the results are tied to the actual commit against which the tests
  # were run.
  console.log "getAndStoreRootBuildCommit for #{jobName} #{rootBuildNumber}"
  url = "#{fullUrl}api/json?tree=actions[lastBuiltRevision[SHA1]],result"
  req = robot.http(url)

  if HUBOT_JENKINS_AUTH
    auth = new Buffer(HUBOT_JENKINS_AUTH).toString('base64')
    req.headers Authorization: "Basic #{auth}"

  req.get() (err, res, body) ->
    if res.statusCode == 200
      buildData = robot.brain.get(rootBuildNumber) or {}
      data = JSON.parse(body)

      result = data.result
      if result != JENKINS_BUILD_STATUS.SUCCESS
        console.log "Job not successful. Can't get commit hash."
        return

      actions = data.actions
      if not actions
        console.log "No actions found from #{url}"
        return

      commitSHA = null
      for action in actions
        if "lastBuiltRevision" in Object.keys(action)
          commitSHA = action.lastBuiltRevision?.SHA1
      if not commitSHA
        console.log "No lastBuiltRevision.SHA1 found at #{url}"
        return

      buildData[BUILD_DATA.COMMIT_SHA] = commitSHA
      robot.brain.set rootBuildNumber, buildData
      console.log "Updated commit_sha for #{jobName} #{rootBuildNumber} to #{commitSHA}"

      message = "#{jobName} completed successfully for issue #{issue} (#{commitSHA[...8]})."
      robot.messageRoom roomToPostMessagesTo, message

      targetURL = "#{HUBOT_JENKINS_URL}/job/#{JENKINS_ROOT_JOB_NAME}/#{rootBuildNumber}"
      description = "#{jobName} #{rootBuildNumber} is running"
      updateGithubBranchStatus(
        "issue_#{issue}"
        GITHUB_REPO_STATUS.PENDING,
        targetURL,
        description,
        commitSHA,
      )


handleFinishedDownstreamJob = (robot, jobName, rootBuildNumber, buildNumber, buildStatus) ->
  console.log "handleFinishedDownstreamJob for #{jobName}, #{rootBuildNumber} with status #{buildStatus}"
  buildData = robot.brain.get(rootBuildNumber) or {}
  if not BUILD_DATA.COMMIT_SHA in Object.keys(buildData)
    errorMsg = "Error: Root build #{rootBuildNumber} doesn't have required rootBuildData 
     to handle #{jobName} #{buildNumber}"
    console.log errorMsg
    console.log "Current buildData: #{buildData}"
    # TODO: We could recover here by:
    # 1. Crawling to the parent job and then getting/storing the root job data
    # 2. After that, kicking off something to crawl the downstream jobs and
    # actually poll for their statuses, just to catch up with anything we might
    # have missed. That ability would also go 80% of the way towards building
    # something that we could run on start to handle any missed notifications
    # while hubot was down.
    return

  statusesKey = "#{rootBuildNumber}_statuses"
  buildStatuses = robot.brain.get(statusesKey) or {}
  buildStatuses[jobName] = buildStatus
  robot.brain.set statusesKey, buildStatuses

  numFinishedDownstreamJobs = Object.keys(buildStatuses).length
  console.log "Number of finished downstream builds from root
   build #{rootBuildNumber}: #{numFinishedDownstreamJobs}"

  if numFinishedDownstreamJobs is buildData[BUILD_DATA.DOWNSTREAM_JOBS_COUNT]
    markGithubBranchAsFinished(rootBuildNumber, buildData, buildStatuses)
    buildData[BUILD_DATA.MARKED_AS_FINISHED] = true
    robot.brain.set rootBuildNumber, buildData
  else
    if buildStatus is JENKINS_BUILD_STATUS.FAILURE
      # This job failed. Even though all of the downstream jobs aren't finished,
      # we can already mark the build as a failure.
      targetURL = "#{HUBOT_JENKINS_URL}/job/#{JENKINS_ROOT_JOB_NAME}/#{rootBuildNumber}"
      description = "Build #{buildNumber} of #{jobName} failed"
      updateGithubBranchStatus(
        "issue_#{buildData[BUILD_DATA.ISSUE_NUMBER]}"
        GITHUB_REPO_STATUS.FAILURE,
        targetURL,
        description,
        buildData[BUILD_DATA.COMMIT_SHA],
      )


jenkinsList = (msg) ->
    url = HUBOT_JENKINS_URL
    job = msg.match[1]
    req = msg.http("#{url}/api/json")

    if HUBOT_JENKINS_AUTH
      auth = new Buffer(HUBOT_JENKINS_AUTH).toString('base64')
      req.headers Authorization: "Basic #{auth}"

    req.get() (err, res, body) ->
        response = ""
        if err
          msg.send "Jenkins says: #{err}"
        else
          try
            content = JSON.parse(body)
            for job in content.jobs
              state = if job.color != "blue" then "FAIL" else "PASS"
              response += "#{state} #{job.name}\n"
            msg.send response
          catch error
            msg.send error


jenkinsLaunchWorkers = (msg) ->
    workerCount = msg.match[1]
    if not workerCount
      workerCount = 1
    if workerCount == "max"
      workerCount = GCE_MACHINE_COUNT
    launchJenkinsWorkers(workerCount)
    msg.send "Launching #{workerCount} Jenkins workers"


module.exports = (robot) ->
  github = require("githubot")(robot)

  github.handleErrors (response) ->
    console.log "Oh noes! A github request returned #{response.statusCode}"
    console.log "and error message: #{response.error}"
    console.log "and body: #{response.body}"

  robot.respond /ci issue ([\d_]+)/i, (msg) ->
    jenkinsBuildIssue(robot, msg)

  robot.respond /ci workers ?(\d+)?/i, (msg) ->
    jenkinsLaunchWorkers(msg)

  robot.respond /message test/i, (msg) ->
    channelId = msg.message.rawMessage.channel
    robot.messageRoom channelId, "pong - channel ID is #{channelId}"

  robot.ci = {
    list: jenkinsList,
    build: jenkinsBuild,
    issue: jenkinsBuildIssue,
    workers: jenkinsLaunchWorkers,
  }

  robot.router.post JENKINS_NOTIFICATION_ENDPOINT, (req, res) ->
    console.log "Post received on #{JENKINS_NOTIFICATION_ENDPOINT}"
    data = req.body

    jobName = data.name
    build = data.build
    if not build
      console.log "No build argument given. Exiting."
      res.end "ok"
      return

    rootBuildNumber = build.parameters.SOURCE_BUILD_NUMBER
    buildNumber = build.number
    buildPhase = build.phase
    buildStatus = build.status

    if buildPhase is JENKINS_BUILD_PHASE.COMPLETED
      handleFinishedDownstreamJob(robot, jobName, rootBuildNumber, buildNumber, buildStatus)

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

    rootBuildNumber = build.number
    if not rootBuildNumber
      console.log "No rootBuildNumber argument given. Exiting."
      res.end "ok"
      return

    fullUrl = build.full_url
    issue = build.parameters.ISSUE
    if not issue
      console.log "No parameters.ISSUE argument given. Exiting."
      res.end "ok"
      return

    roomToPostMessagesTo = robot.brain.get issue
    if not roomToPostMessagesTo
      roomToPostMessagesTo = process.env.HUBOT_SLACK_CHANNEL

    if build.phase is JENKINS_BUILD_PHASE.STARTED
      message = "Tests for issue ##{issue} has started: #{fullUrl}"
      robot.messageRoom roomToPostMessagesTo, message

    else if build.phase is JENKINS_BUILD_PHASE.COMPLETED and build.status is JENKINS_BUILD_STATUS.SUCCESS
      registerRootJobStarted(robot, fullUrl, issue, rootJobName, rootBuildNumber, roomToPostMessagesTo)
      getAndStoreRootBuildCommit(robot, rootJobName, rootBuildNumber, fullUrl, issue, roomToPostMessagesTo)

    res.end "ok"
