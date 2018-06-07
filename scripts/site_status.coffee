# Description
#   Scan site status for errors, and display them
#
# Dependencies:
#   None
#
# Configuration:
#   None
#
# Commands:
#   hubot status <environment>
#
# Author:
#   kylegibson

APP_SERVERS =
    live: [
        'app0.policystat.com',
        'app1.policystat.com',
        'dyno0-00.policystat.com',
        'dyno1-00.policystat.com',
    ]
    training: [
        'app0.pstattraining.com',
        'app1.pstattraining.com',
    ]
    beta: [
        'app0.pstatbeta.com',
        'app1.pstatbeta.com',
        'dyno0-00.pstatbeta.com',
        'dyno1-00.pstatbeta.com',
    ]
    pstattest: [
        'app0.pstattest.com',
        'app1.pstattest.com',
    ]
TIMEOUT = 5000

http = require 'http'

# hubot uses scoped-http-client to implement robot.http(). unfortunately this
# implementation leaves proper error handling seriously wanting, so here's a
# better implementation. this interface mirrors, somewhat, a Promise
get = (options) ->
    try
        req = http.get options.url
    catch error
        options.fail? null, error
        return
    if options.timeout?
        req.setTimeout options.timeout, () ->
            error = new Error 'connection timed out'
            error.code = 'ETIMEOUT'
            req.emit 'error', error
            req._hadError = true
            req.abort()
    req.on 'response', (res) ->
        body = ''
        res.on 'data', (chunk) ->
            body += chunk
        res.on 'end', ->
            options.done? req, res, body
    req.on 'error', (error) ->
        options.fail? req, error
    req


getServerStatusJSON = (robot, msg, server) ->
    console.log 'server', server
    status_url = server + "/site_status"
    get(
        url: "http://#{status_url}/status.json"
        timeout: TIMEOUT
        done: (req, res, body) ->
            try
                status = JSON.parse(body)
            catch error
                msg.send error
                return

            response_status = []
            failing = []
            if status.all_pass
                response_status.push 'ALL_PASS'
            else
                for check in status.status_checks
                    if not check.status
                        failing.push check.name
            if status.no_critical
                response_status.push 'NO_CRITICAL'

            load = [
                status.loadavg.avg1,
                status.loadavg.avg5,
                status.loadavg.avg15
            ]
            response = [
                "#{status_url}: #{response_status.join(' ')}"
            ]
            if failing.length > 0
                response.push "Failing #{failing.join(' ')}"
            response.push "Load: #{load.join(' ')}"
            response.push "Version: #{status.version}"
            msg.send response.join(' | ')
        fail: (req, error) ->
            msg.send "#{status_url}: #{error}"
    )

reportEnvironmentStatus = (robot, msg, env) ->
    console.log 'environment', env
    for server in APP_SERVERS[env]
        getServerStatusJSON robot, msg, server

handleStatusRequest = (robot, msg) ->
    environment = msg.match[1].trim()
    if environment not of APP_SERVERS
        return
    reportEnvironmentStatus environment

module.exports = (robot) ->
    robot.respond /status (.*)$/i, (msg) ->
        handleStatusRequest robot, msg
    robot.hear /incident .+ triggered .+ DOWN/i, (msg) ->
        return if not msg.message.user.name == 'PagerDuty'
        reportEnvironmentStatus 'live'
