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

cheerio = require('cheerio')

getServerStatus = (robot, msg, server) ->
    console.log 'server', server
    status_url = server + "/site_status/"
    robot.http("http://" + status_url).get() (err, res, body) ->
        if err
            msg.send "Sorry, the tubes are broken: #{err}"
            return
        $ = cheerio.load(body)
        statuses = $('.status')
        top_status = statuses.first().text().trim().replace("\n", "")
        console.log "top_status '#{top_status}'"
        response = ""
        if top_status == ''
            response = server + ' has errors'
        else
            response = "#{status_url}: #{top_status}"
        msg.send response

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
