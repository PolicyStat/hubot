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
          markIssueAsPending(issue, buildLink)
        else
          msg.send "Getting job info from #{jobUrl} failed with status: #{res.statusCode}"

        # TODO: Store the job numbers, who requested them and the issue
        # number in memcached. Then use Heroku's cron job stuff to periodically
        # check these things in Memcached and then post to the Github issue
        # with the results. If they fail, also notify the requester in
        # hipchat with the pull request link

markIssueAsPending = (issue_num, buildLink) ->
  bot_github_repo = github.qualified_repo process.env.HUBOT_GITHUB_REPO

  refs_url = "repos/#{bot_github_repo}/git/refs/heads/issue_#{issue_num}"

  sha = ""
  github.get refs_url, (resp) ->
    sha = resp.object.sha
    url = "repos/#{bot_github_repo}/statuses/#{sha}"
    data = {
      state: "pending",
      target_url: buildLink,
      description: "Issue #{issue_num} is running."}
    github.post url, data, (comment_obj) ->
      console.log("Github issue #{issue_num} marked as pending.")

updateGithubStatus = (upstream_build_num, build_data) ->
  issue_num = build_data.issue_num
  build_statuses = build_data.statuses
  bot_github_repo = github.qualified_repo process.env.HUBOT_GITHUB_REPO

  refs_url = "repos/#{bot_github_repo}/git/refs/heads/issue_#{issue_num}"

  sha = ""
  github.get refs_url, (resp) ->
    sha = resp.object.sha
    url = "repos/#{bot_github_repo}/statuses/#{sha}"

    issue_status = "success"
    project_num = Object.keys(build_statuses).length
    status_description = "Build #{upstream_build_num} succeeded! #{project_num} downstream projects completed successfully."
    target_url = "#{process.env.HUBOT_JENKINS_URL}/job/pstat_ticket/#{upstream_build_num}"

    failed_nodes = []
    for key, value of build_statuses
      if value.status == "FAILURE"
        issue_status = "failure"
        failed_nodes.push(key)

    if issue_status is "failure"
      status_description = "The following downstream projects failed: "
      for node in failed_nodes
        status_description += node + " "

    data = {
      "state": issue_status,
      "target_url": target_url,
      "description": status_description
    }
    github.post url, data, (resp) ->
      console.log("Status for issue #{issue_num} updated: #{data.state}")

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

  robot.router.post process.env.JENKINS_NOTIFICATION_ENDPOINT, (req) ->
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
      build_data = robot.brain.get(upstream_build_num) or {}
      build_data['issue_num'] = params.ISSUE
      build_statuses = build_data.statuses or {}
      build_statuses[project] = build_status
      build_data['statuses'] = build_statuses

      num_builds = Object.keys(build_statuses).length
      console.log("Number of finished builds for upstream build " + upstream_build_num + ": " + num_builds)
      robot.brain.set upstream_build_num, build_data
      if num_builds is process.env.NUM_JENKINS_PROJECTS
        updateGithubStatus(upstream_build_num, build_data)
        robot.brain.remove upstream_build_num
