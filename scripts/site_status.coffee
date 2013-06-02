# Description
#   Scan site status for errors, and display them
#
# Dependencies:
#   "cheerio": ""
#
# Configuration:
#   None
#
# Commands:
#   hubot (live|training|beta) status
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
TIMEOUT = 3000

cheerio = require 'cheerio'
http = require 'http'

# hubot uses scoped-http-client to implement robot.http(). unfortunately this
# implementation leaves proper error handling seriously wanting, so here's a
# better implementation. this interface mirrors, somewhat, a Promise
get = (options) ->
    req = http.get options.url
    if options.timeout?
        req.setTimeout options.timeout, () ->
            error = new Error('connection timed out')
            error.code = 'ETIMEOUT'
            req.emit 'error', error
            req._hadError = true
            req.abort()
    req.on 'response', (res) ->
        body = ''
        res.on 'data', (chunk) ->
            body += chunk
        res.on 'end', ->
            options.done?(req, res, body)
    req.on 'error', (error) ->
        options.fail?(req, error)
    req


getServerStatus = (robot, msg, server) ->
    console.log 'server', server
    status_url = server + "/site_status"
    get(
        url: "http://#{status_url}/"
        timeout: TIMEOUT
        done: (req, res, body) ->
            $ = cheerio.load(body)
            statuses = $('.status')
            top_status = statuses.first().text().trim().replace("\n", "")
            console.log "top_status '#{top_status}'"
            response = ""
            if top_status == ''
                response = status_url + ' has errors'
            else
                response = "#{status_url}: #{top_status}"
            msg.send response
        fail: (req, error) ->
            msg.send "#{status_url}: #{error}"
    )

handleStatusRequest = (robot, msg) ->
    environment = msg.match[1].trim()
    if environment not of APP_SERVERS
        return
    console.log 'environment', environment
    for server in APP_SERVERS[environment]
        getServerStatus robot, msg, server

module.exports = (robot) ->
    robot.respond /status (.*)$/i, (msg) ->
        handleStatusRequest robot, msg
