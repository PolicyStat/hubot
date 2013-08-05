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
#

github = {}

jenkinsBuild = (msg) ->
    url = process.env.HUBOT_JENKINS_URL
    job = msg.match[1]

    path = "#{url}/job/#{job}/build"

    req = msg.http(path)

    if process.env.HUBOT_JENKINS_AUTH
      auth = new Buffer(process.env.HUBOT_JENKINS_AUTH).toString('base64')
      req.headers Authorization: "Basic #{auth}"

    req.header('Content-Length', 0)
    req.post() (err, res, body) ->
        if err
          msg.send "Jenkins says: #{err}"
        else if res.statusCode == 302
          msg.send "Build started for #{job} #{res.headers.location}"
        else
          msg.send "Jenkins says: #{body}"

notifyGithubOfJob = (msg, jobUrl, issue) ->
    # Now get the downstreamProjects that this build will trigger
    path = "#{jobUrl}/api/json?tree=url,nextBuildNumber,displayName"
    req = msg.http(path)
    if process.env.HUBOT_JENKINS_AUTH
      auth = new Buffer(process.env.HUBOT_JENKINS_AUTH).toString('base64')
      req.headers Authorization: "Basic #{auth}"

    req.header('Content-Length', 0)
    req.get() (err, res, body) ->
        if err
          errorMessage = "Getting job info from #{jobUrl} failed with status: #{err}"
          console.log(errorMessage)
          msg.send errorMessage
        else if res.statusCode == 200
          json = JSON.parse(body)
          buildLink = "#{json.url}#{json.nextBuildNumber}"
          msg.send "#{json.displayName} will be: #{buildLink}"
          updateGithubBranchStatus({
            branchName: "issue_#{issue_num}",
            state: "pending",
            stateURL: buildLink,
            description: "Issue #{issue_num} is running.",
          })
          markIssueAsPending(issue, buildLink)
        else
          msg.send "Getting job info from #{jobUrl} failed with status: #{res.statusCode}"

        # TODO: Store the job numbers, who requested them and the issue
        # number in memcached. Then use Heroku's cron job stuff to periodically
        # check these things in Memcached and then post to the Github issue
        # with the results. If they fail, also notify the requester in
        # hipchat with the pull request link

updateGithubBranchStatus = (opts) ->
  repo = github.qualified_repo process.env.HUBOT_GITHUB_REPO
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
      console.log("Github branch #{opts.branchName} marked as #{state}.")

markGithubBranchAsFinished = (upstream_build_num, build_statuses) ->
  issue_num = build_statuses.issue_num
  delete build_statuses.issue_num

  project_num = Object.keys(build_statuses).length

  failed_nodes = []
  issue_status = "success"
  for key, value of build_statuses
    if value.status == "FAILURE"
      issue_status = "failure"
      failed_nodes.push(key)

  if issue_status is "failure"
    status_description = "The following downstream projects failed: "
    for node in failed_nodes
      status_description += node + " "
  else
    status_description = "Build #{upstream_build_num} succeeded! #{project_num} downstream projects completed successfully."

  stateURL = "#{process.env.HUBOT_JENKINS_URL}/job/pstat_ticket/#{upstream_build_num}"
  updateGithubBranchStatus({
    branchName: "issue_#{issue_num}",
    state: issue_status,
    stateURL: stateURL,
    description: status_description,
  })

jenkinsBuildIssue = (msg) ->
    url = process.env.HUBOT_JENKINS_URL
    issue = msg.match[1]
    jobName = "pstat_ticket"

    path = "#{url}/job/#{jobName}/buildWithParameters?ISSUE=#{issue}"

    req = msg.http(path)
    if process.env.HUBOT_JENKINS_AUTH
      auth = new Buffer(process.env.HUBOT_JENKINS_AUTH).toString('base64')
      req.headers Authorization: "Basic #{auth}"

    req.header('Content-Length', 0)
    req.post() (err, res, body) ->
        if err
          msg.send "Jenkins says: #{err}"
        else if res.statusCode == 302
          msg.send "Build started for issue #{issue} #{res.headers.location}"

          notifyGithubOfJob(msg, res.headers.location, issue)

        else
          msg.send "Jenkins says: #{body}"

jenkinsList = (msg) ->
    url = process.env.HUBOT_JENKINS_URL
    job = msg.match[1]
    req = msg.http("#{url}/api/json")

    if process.env.HUBOT_JENKINS_AUTH
      auth = new Buffer(process.env.HUBOT_JENKINS_AUTH).toString('base64')
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

  robot.router.post '/hubot/build-status', (req) ->
    data = req.body
    project = data.name
    params = data.build.parameters
    upstream_build_num = params.SOURCE_BUILD_NUMBER
    build_status = {
      'build_num': data.build.number,
      'phase': data.build.phase,
      'status': data.build.status
    }
    console.log(build_status)
    if build_status.phase is "FINISHED"
      build_statuses = robot.brain.get(upstream_build_num) or {}
      build_statuses['issue_num'] = params.ISSUE
      build_statuses[project] = build_status

      num_builds = Object.keys(build_statuses).length - 1
      console.log("Number of finished builds for upstream build " + upstream_build_num + ": " + num_builds)
      robot.brain.set upstream_build_num, build_statuses
      if num_builds is 6
        markGithubBranchAsFinished(upstream_build_num, build_statuses)
        robot.brain.remove upstream_build_num
