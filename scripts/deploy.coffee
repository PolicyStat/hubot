moment = require('moment')
AWS = require('aws-sdk')
AWS.config.update({region: process.env.AWS_DEFAULT_REGION})

DEPLOY_QUEUE_URL = process.env.DEPLOY_QUEUE_URL

module.exports = (robot) ->
  robot.respond /deploy pstattest (.*)+/i, (msg) ->
    gitReference = msg.match[1].trim()
    msg.send 'Queuing pstattest deploy for "' + gitReference + '"'

    timestamp = moment().format 'MMDD-HHmm'  # e.g. 0901-1341

    params =
      MessageBody: 'Deploy'
      MessageAttributes:
        Environment:
          DataType: 'String'
          StringValue: 'pstattest'
        GitReference:
          DataType: 'String'
          StringValue: gitReference
      MessageGroupId: 'deploy'
      MessageDeduplicationId: timestamp
      QueueUrl: DEPLOY_QUEUE_URL

    sqs = new AWS.SQS()
    sqs.sendMessage params, (err, data) ->
      if err
        console.log 'Error', err
        return
      msg.send 'Deploy to pstattest has been queued'
      console.log 'Deploy to pstattest has been queued', data.MessageId
