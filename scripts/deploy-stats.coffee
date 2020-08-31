moment = require('moment')
google = require('googleapis')

CREDENTIALS_CLIENT_EMAIL = process.env.DEV_DASH_CREDENTIALS_CLIENT_EMAIL
CREDENTIALS_PRIVATE_KEY = process.env.DEV_DASH_CREDENTIALS_PRIVATE_KEY
if CREDENTIALS_PRIVATE_KEY
  CREDENTIALS_PRIVATE_KEY = CREDENTIALS_PRIVATE_KEY.replace(/\\n/g, "\n")
SPREADSHEET_KEY = process.env.DEV_DASH_SPREADSHEET_KEY
SPREADSHEET_DATA_RANGE = process.env.DEV_DASH_SPREADSHEET_DATA_RANGE
SPREADSHEET_URL = process.env.DEV_DASH_SPREADSHEET_URL

AUTH_SCOPES = ['https://www.googleapis.com/auth/spreadsheets.readonly']

showDeployStats = (msg) ->
  msg.send 'Fetching deploy statistics'
  currentMonth = moment().format 'YYYY-MM-01'
  jwtClient = new google.auth.JWT(
    CREDENTIALS_CLIENT_EMAIL,
    null,
    CREDENTIALS_PRIVATE_KEY,
    AUTH_SCOPES,
    null
  )
  jwtClient.authorize (authErr, tokens) ->
    if authErr
      console.log 'Authentication error:', authErr
      msg.send authErr
      return
    sheets = google.sheets('v4')
    options =
      auth: jwtClient
      spreadsheetId: SPREADSHEET_KEY
      range: SPREADSHEET_DATA_RANGE
      majorDimension: 'ROWS'

    sheets.spreadsheets.values.get options, (err, resp) ->
      if err
        console.log 'Error fetching spreadsheet data:', err
        msg.send err
        return

      results = {}
      for row in resp.values
        results[row[0]] = row[1..]

      engineers = results.Month[2..]
      currentMonthRow = results[currentMonth]
      totalRow = results.Total

      sortDescending = (a, b) -> b[0] - a[0]
      mapDeployAndEngineerName = (item, index) ->
        [parseInt(item, 10), engineers[index]]

      totalEngineerDeploys = totalRow[2..].map mapDeployAndEngineerName
      totalEngineerDeploys.sort sortDescending

      currentMonthEngineerDeploys = currentMonthRow[2..].map mapDeployAndEngineerName
      currentMonthEngineerDeploys.sort sortDescending

      msg.send "### Deploys Since #{currentMonth} ###"
      msg.send "Total: #{currentMonthRow[0]}"
      for item, index in currentMonthEngineerDeploys
        namePadded = pad(item[1], 8, ' ')
        msg.send "#{index+1}. #{namePadded}#{item[0]} deploys"

      msg.send "### Deploys This Year ###"
      msg.send "Total: #{totalRow[0]}"
      for item, index in totalEngineerDeploys
        namePadded = pad(item[1], 8, ' ')
        msg.send "#{index+1}. #{namePadded}#{item[0]} deploys"

      msg.send "More: #{SPREADSHEET_URL}"

module.exports = (robot) ->
  robot.respond /deploy stats/i, (msg) ->
    showDeployStats msg

pad = (val, length, padChar = '0') ->
  val += ''
  numPads = length - val.length
  if (numPads > 0) then val + new Array(numPads + 1).join(padChar) else val
