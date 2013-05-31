# Description
#   Scan site status for errors, and display them
#
# Dependencies:
#   "htmlparser": "1.7.6"
#   "soupselect": "0.2.0"
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

Select = require("soupselect").select
HtmlParser = require "htmlparser"

module.exports = (robot) ->
    robot.respond /(live|training|beta) status$/i, (msg) ->
        site = msg.match[1]
        for server in APP_SERVERS[site]
            msg.http(server + '/site_status/').get() (err, res, body) ->
                handler = new HtmlParser.DefaultHandler()
                parser = new HtmlParser.Parser handler
                parser.parseComplete body
                status = Select handler.dom, ".status"
                response = ""
                if status == 'ALL_PASS NO_CRITICAL'
                    response = server + ' looks good'
                else
                    response = server + ' has errors'
                msg.send response
