# Interact with your Jenkins CI server
#
# You need to set the following variables:
#   HUBOT_JENKINS_URL = "http://ci.example.com:8080"
#
# The following variables are optional
#   HUBOT_JENKINS_AUTH: for authenticating the trigger request (user:password)
#
# jenkins build <job> - builds the specified Jenkins job
# jenkins issue <issue_number>- builds the pstat_ticket job with the
#   corresponding issue_<issue_number> branch
# jenkins list - lists Jenkins jobs
#
# Forked to make building a pstat_ticket branch less verbose.
#

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

jenkinsBuildIssue = (msg) ->
    url = process.env.HUBOT_JENKINS_URL
    issue = msg.match[1]

    path = "#{url}/job/pstat_ticket/buildWithParameters?ISSUE=#{issue}"

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
          # TODO:
          # Determine the unittest and selenium job numbers that will be used
          # based on jobs currently in the queue. Use that to predict the URLs
          # for these respective jobs and post them to both Hipchat and the
          # corresponding github pull request
          # Future enhancement:
          # Store the job numbers, who requested them and the issue number in memcached
          # Use Heroku's cron job stuff to periodically check these things in Memcached and then post to the Github issue with the results.
          # If they fail, also notify the requester in hipchat with the pull request link
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
