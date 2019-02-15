# Description:
#   Queue a deploy to either pstattest or beta
#
# Dependencies:
#   "moment": "^2.21.0"
#
# Configuration:
#   DEPLOY_QUEUE_URL
#
# Commands:
#   hubot deploy <pstattest|beta> <git_branch> - Deploy <git_branch> to either pstattest or beta

moment = require('moment')
AWS = require('aws-sdk')
AWS.config.update({region: process.env.AWS_DEFAULT_REGION})

DEPLOY_QUEUE_URL = process.env.DEPLOY_QUEUE_URL

queueDeploy = (msg, environment, reference) ->
  msg.send "Queuing #{environment} deploy for #{reference}"

  timestamp = moment().format 'MMDD-HHmm'  # e.g. 0901-1341

  params =
    MessageBody: 'Deploy'
    MessageAttributes:
      Environment:
        DataType: 'String'
        StringValue: environment
      GitReference:
        DataType: 'String'
        StringValue: reference
    MessageGroupId: 'deploy'
    MessageDeduplicationId: timestamp
    QueueUrl: DEPLOY_QUEUE_URL

  sqs = new AWS.SQS()
  sqs.sendMessage params, (err, data) ->
    if err
      console.log 'Error', err
      return
    msg.send "Deploy to #{environment} has been queued"
    console.log "Deploy to #{environment} has been queued", data.MessageId


module.exports = (robot) ->
  robot.respond /deploy pstattest (.*)+/i, (msg) ->
    reference = msg.match[1].trim()
    queueDeploy msg, "pstattest", reference
  robot.respond /deploy beta (.*)+/i, (msg) ->
    reference = msg.match[1].trim()
    queueDeploy msg, "beta", reference
