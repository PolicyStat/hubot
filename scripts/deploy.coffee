module.exports = (robot) ->
  robot.respond /deploy pstattest (.*)+/i, (msg) ->
    branch = msg.match[1].trim()
    msg.send 'Queuing pstattest deploy for "' + branch + '"'
