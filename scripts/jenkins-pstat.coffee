# Interact with your Jenkins CI server
#
# You need to set the following variables:
#   HUBOT_JENKINS_URL = "http://ci.example.com:8080"
#
# The following variables are optional
#   HUBOT_JENKINS_AUTH: for authenticating the trigger request (user:password)
#
# ci build <job> - builds the specified Jenkins job
# ci issue <issue_number>- builds the pstat_ticket job with the
#   corresponding issue_<issue_number> branch
# ci list - lists Jenkins jobs
#
# Forked to make building a pstat_ticket branch less verbose.

util = require 'util'

github = {}

HUBOT_JENKINS_URL = process.env.HUBOT_JENKINS_URL
HUBOT_JENKINS_AUTH = process.env.HUBOT_JENKINS_AUTH
HUBOT_JENKINS_URL = process.env.HUBOT_JENKINS_URL
HUBOT_GITHUB_REPO = process.env.HUBOT_GITHUB_REPO

JENKINS_NOTIFICATION_ENDPOINT = process.env.JENKINS_NOTIFICATION_ENDPOINT or "/hubot/build-status"
JENKINS_ROOT_JOB_NOTIFICATION_ENDPOINT = process.env.JENKINS_ROOT_JOB_NOTIFICATION_ENDPOINT or "/hubot/root-build-status"
JENKINS_ROOT_JOB_NAME = process.env.JENKINS_ROOT_JOB_NAME or "pstat_ticket"

BUILD_DATA = {
  'COMMIT_SHA': 'commit_SHA',
  'ISSUE_NUMBER': 'issue_number',
  'DOWNSTREAM_JOBS_COUNT': 'downstream_jobs_count'
}
JENKINS_BUILD_STATUS = {
  'FAILURE': 'FAILURE',
  'SUCCESS': 'SUCCESS',
  'ABORTED': 'ABORTED',
}
JENKINS_BUILD_PHASE = {
  'FINISHED': 'FINISHED',
  'STARTED': 'STARTED',
}
GITHUB_REPO_STATUS = {
  'PENDING': 'pending',
  'FAILURE': 'failure',
  'SUCCESS': 'success',
}


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


registerRootJobStarted = (robot, msg, jobUrl, issue, jobName) ->
  baseUrl = HUBOT_JENKINS_URL
  # We use the job base URL, instead of the URL for the specific run,
  # because we need access to the `downstreamProjects` to know
  # when all of the downstream jobs are actually finished
  url = "#{baseUrl}/job/#{jobName}/api/json?tree=url,downstreamProjects,nextBuildNumber,displayName"
  req = msg.http(url)

  if HUBOT_JENKINS_AUTH
    auth = new Buffer(HUBOT_JENKINS_AUTH).toString('base64')
    req.headers Authorization: "Basic #{auth}"

  req.get() (err, res, body) ->
    if err
      errorMessage = "Getting job info from #{url} failed with status: #{err}"
      console.log(errorMessage)
      msg.send errorMessage
    else if res.statusCode == 200
      json = JSON.parse(body)
      buildLink = "#{json.url}#{json.nextBuildNumber}"
      msg.send "#{json.displayName} will be: #{buildLink}"
      storeRootBuildData(robot, json.nextBuildNumber, json.downstreamProjects, issue)
    else
      msg.send "Getting job info from #{jobUrl} failed with status: #{res.statusCode}"


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
    jobName = JENKINS_ROOT_JOB_NAME

    url = "#{baseUrl}/job/#{jobName}/buildWithParameters?ISSUE=#{issue}"

    req = msg.http(url)
    if HUBOT_JENKINS_AUTH
      auth = new Buffer(HUBOT_JENKINS_AUTH).toString('base64')
      req.headers Authorization: "Basic #{auth}"

    req.header('Content-Length', 0)
    req.post() (err, res, body) ->
        if err
          msg.send "Jenkins says: #{err}"
        else if res.statusCode == 302
          msg.send "Build started for issue #{issue} #{res.headers.location}"
          registerRootJobStarted(robot, msg, res.headers.location, issue, jobName)
        else
          msg.send "Jenkins says: #{body}"


storeRootBuildData = (robot, rootBuildNumber, downstreamProjects, issueNumber) ->
  console.log "Storing root build data for #{rootBuildNumber}"
  # Store the number of downstream jobs and issue number
  buildData = robot.brain.get(rootBuildNumber) or {}

  buildData[BUILD_DATA.ISSUE_NUMBER] = issueNumber
  buildData[BUILD_DATA.DOWNSTREAM_JOBS_COUNT] = downstreamProjects.length
  robot.brain.set rootBuildNumber, buildData


getAndStoreRootBuildCommit = (robot, jobName, rootBuildNumber, fullUrl) ->
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
      console.log "Setting commit_sha to #{commitSHA} for #{jobName} #{rootBuildNumber}"

      updateGithubBranchStatus(
        "issue_#{buildData[BUILD_DATA.ISSUE_NUMBER]}"
        GITHUB_REPO_STATUS.PENDING,
        targetURL,
        description,
        buildData[BUILD_DATA.COMMIT_SHA],
      )


handleFinishedDownstreamJob = (robot, jobName, rootBuildNumber, buildNumber, buildStatus) ->
  console.log "handleFinihedDownstreamJob for #{jobName}, #{rootBuildNumber} with status #{buildStatus}"
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

  if "#{numFinishedDownstreamJobs}" is buildData[BUILD_DATA.DOWNSTREAM_JOBS_COUNT]
    markGithubBranchAsFinished(rootBuildNumber, buildData, buildStatuses)
    robot.brain.remove rootBuildNumber
    robot.brain.remove statusesKey
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

module.exports = (robot) ->
  github = require("githubot")(robot)

  robot.respond /ci issue ([\d_]+)/i, (msg) ->
    jenkinsBuildIssue(robot, msg)

  robot.respond /ci build ([\w\.\-_]+)/i, (msg) ->
    jenkinsBuild(msg)

  robot.respond /ci list/i, (msg) ->
    jenkinsList(msg)

  robot.ci = {
    list: jenkinsList,
    build: jenkinsBuild,
    issue: jenkinsBuildIssue,
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

    if buildPhase is JENKINS_BUILD_PHASE.FINISHED
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

    buildData = robot.brain.get(rootBuildNumber) or {}
    if BUILD_DATA.COMMIT_SHA in Object.keys(buildData)
      console.log "Commit SHA already gathered for #{rootJobName} #{rootBuildNumber}"
      res.end "ok"
      return

    getAndStoreRootBuildCommit(robot, rootJobName, rootBuildNumber, fullUrl)

    res.end "ok"
