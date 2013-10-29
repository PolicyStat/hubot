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

registerRootJobStarted = (msg, jobUrl, issue, jobName) ->
  baseUrl = HUBOT_JENKINS_URL
  # We use the job base URL, instead of the URL for the specific run,
  # because we need access to the `downstreamProjects` to know
  # when all of the downstream jobs are actually finished
  url = "#{baseUrl}/job/#{jobName}/api/json?tree=url,downstreamProjects,nextBuildNumber,displayName"
  req = msg.http(url)

  if HUBOT_JENKINS_AUTH
    auth = new Buffer(HUBOT_JENKINS_AUTH).toString('base64')
    req.headers Authorization: "Basic #{auth}"

  req.header('Content-Length', 0)
  req.get() (err, res, body) ->
    if err
      errorMessage = "Getting job info from #{url} failed with status: #{err}"
      console.log(errorMessage)
      msg.send errorMessage
    else if res.statusCode == 200
      json = JSON.parse(body)
      buildLink = "#{json.url}#{json.nextBuildNumber}"
      msg.send "#{json.displayName} will be: #{buildLink}"
      # Tell github to set the branch repo status to pending
      updateGithubBranchStatus({
        branchName: "issue_#{issue}",
        state: "pending",
        stateURL: buildLink,
        description: "Issue #{issue} is running.",
      })
      storeRootBuildData(json.nextBuildNumber, json.downstreamProjects, issue)
    else
      msg.send "Getting job info from #{jobUrl} failed with status: #{res.statusCode}"


updateGithubBranchStatus = (opts) ->
  console.log "Updating github branch as #{opts.state}"
  repo = github.qualified_repo HUBOT_GITHUB_REPO
  githubBranchRefsUrl = "repos/#{repo}/git/refs/heads/#{opts.branchName}"

  sha = ""
  github.get githubBranchRefsUrl, (resp) ->
    sha = resp.object.sha
    githubPostStatusUrl = "repos/#{repo}/statuses/#{sha}"
    data = {
      state: opts.state,
      target_url: opts.stateURL,
      description: opts.description,
    }
    github.post githubPostStatusUrl, data, (comment_obj) ->
      console.log "Github branch #{opts.branchName} marked as #{opts.state}."


markGithubBranchAsFinished = (rootBuildNumber, build_data) ->
  console.log "markGithubBranchAsFinished #{rootBuildNumber}"
  issueNumber = build_data.issueNumber
  build_statuses = build_data.statuses
  bot_github_repo = github.qualified_repo HUBOT_GITHUB_REPO

  project_num = Object.keys(build_statuses).length

  failed_nodes = []
  success = true
  issue_status = "success"
  for key, value of build_statuses
    if value.status != "SUCCESS"
      success = false
      failed_nodes.push(key)

  if not success
    status_description = "The following downstream projects failed: "
    for node in failed_nodes
      status_description += node + " "
  else
    status_description = "Build #{rootBuildNumber} succeeded! #{project_num} downstream projects completed successfully."

  stateURL = "#{HUBOT_JENKINS_URL}/job/#{JENKINS_ROOT_JOB_NAME}/#{rootBuildNumber}"
  updateGithubBranchStatus({
    branchName: "issue_#{issueNumber}",
    state: if success then "success" else "failure",
    stateURL: stateURL,
    description: status_description,
  })

jenkinsBuildIssue = (msg) ->
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

          registerRootJobStarted(msg, res.headers.location, issue, jobName)

        else
          msg.send "Jenkins says: #{body}"


storeRootBuildData = (rootBuildNumber, downstreamProjects, issueNumber) ->
  # Store the number of downstream jobs and issue number
  buildData = robot.brain.get(rootBuildNumber) or {}

  buildData[BUILD_DATA.ISSUE_NUMBER] = issueNumber
  buildData[BUILD_DATA.DOWNSTREAM_JOBS_COUNT] = downstreamProjects.length
  robot.brain.set rootBuildNumber, buildData


getAndStoreRootBuildCommit = (msg, jobName, rootBuildNumber, fullUrl) ->
  # We need to get the SHA for this set of builds one time, after it completes,
  # and associate it with the build number in Hubot's persistent "brain"
  # storage. After that, we tie all of the actions for that build to the same
  # SHA. This lets us run multiple simultaneous builds against a branch for
  # different commits. It also ensures that if we add commits after a build
  # starts, the results are tied to the actual commit against which the tests
  # were run.

  # TODO: How do you traverse objects down multiple levels?
  url = "#{fullUrl}/api/json?tree=changeSet[items[commitId]]"
  req = msg.http(url)

  if HUBOT_JENKINS_AUTH
    auth = new Buffer(HUBOT_JENKINS_AUTH).toString('base64')
    req.headers Authorization: "Basic #{auth}"

  req.get() (err, res, body) ->
    if res.statusCode == 200
      buildData = robot.brain.get(rootBuildNumber) or {}
      data = JSON.parse(body)

      buildData[BUILD_DATA.COMMIT_SHA] = data.changeSet.items.commitId
      robot.brain.set rootBuildNumber, buildData


handleFinishedDownstreamJob = (msg, jobName, rootBuildNumber, buildNumber, buildStatus) ->
  buildData = robot.brain.get(rootBuildNumber) or {}
  if not BUILD_DATA.COMMIT_SHA in Object.keys(buildData)
    errorMsg = "Root build #{rootBuildNumber} doesn't have required rootBuildData 
     to handle #{jobName} #{buildNumber}"
    console.log errorMsg
    console.log "Current buildData: #{buildData}"
    msg.send errorMsg
    return

  statusesKey = "#{rootBuildNumber}_statuses"
  buildStatuses = robot.brain.get(statusesKey) or {}
  buildStatuses[jobName] = buildStatus
  robot.brain.set statusesKey, buildStatuses

  numFinishedDownstreamJobs = Object.keys(buildStatuses).length
  console.log "Number of finished builds for upstream 
   build #{rootBuildNumber}: #{numFinishedDownstreamJobs}"

  if "#{numFinishedDownstreamJobs}" is buildData[BUILD_DATA.DOWNSTREAM_JOBS_COUNT]
    markGithubBranchAsFinished(rootBuildNumber, buildData)
    robot.brain.remove rootBuildNumber
    robot.brain.remove statusesKey

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
    jenkinsBuildIssue(msg)

  robot.respond /ci build ([\w\.\-_]+)/i, (msg) ->
    jenkinsBuild(msg)

  robot.respond /ci list/i, (msg) ->
    jenkinsList(msg)

  robot.ci = {
    list: jenkinsList,
    build: jenkinsBuild,
    issue: jenkinsBuildIssue,
  }

  robot.router.post JENKINS_NOTIFICATION_ENDPOINT, (req) ->
    console.log "Post received on #{JENKINS_NOTIFICATION_ENDPOINT} #{util.inspect req}"
    data = req.body
    jobName = data.name
    rootBuildNumber = data.build.parameters.SOURCE_BUILD_NUMBER
    buildNumber = data.build.number
    buildPhase = data.build.phase
    buildStatus = data.build.status

    if buildPhase is "FINISHED"
      # TODO: How do I get myself a `msg` object?
      handleFinishedDownstreamJob(msg, jobName, rootBuildNumber, buildNumber, buildStatus)

  robot.router.post JENKINS_ROOT_JOB_NOTIFICATION_ENDPOINT, (req) ->
    console.log "Post received on #{JENKINS_ROOT_JOB_NOTIFICATION_ENDPOINT} #{util.inspect req}"
    data = req.body
    rootJobName = data.name
    rootBuildNumber = data.build.number
    fullUrl = data.build.full_url

    buildData = robot.brain.get(rootBuildNumber) or {}
    if BUILD_DATA.ISSUE_NUMBER in Object.keys(buildData)
      console.log "Root build data already gathered for #{rootJobName} #{rootBuildNumber}"
      return

    # TODO: How do I get myself a `msg` object?
    getAndStoreRootBuildCommit(msg, rootJobName, rootBuildNumber, fullUrl)
