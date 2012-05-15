# Have Hubot berate people who ask him about pstattraining
#
# <optional @username> <any content with pstattraining>
#
# Examples
#
# @jason wants to know the pstattraining schedule
# when is the next pstattraining flash?
#


QUIPS = [
  "let me google (calendar) that for you",
  "you're such a forgetful Freddie",
  "there's an app for that",
  "that is an excellent question"
]
CALENDAR_URL = "http://www.google.com/calendar/embed?src=policystat.com_2fansbbfl1sakdikbat23240a8%40group.calendar.google.com&ctz=America/New_York"

module.exports = (robot) ->
  robot.respond /(?:@(\w*))? .* pstattraining.*/i, (msg) ->
    link = ""
    # Make this message on behalf of a user
    link += "#{msg.match[1]}: " if msg.match[1]
    # Insert a quip
    randomNumber = Math.ceil Math.random() * QUIPS.length
    link += QUIPS[randomNumber] + ": " + CALENDAR_URL

    msg.send link
