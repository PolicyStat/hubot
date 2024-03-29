# Description:
#   Interact with your Jenkins CI server
#
# Configuration:
#   HUBOT_JENKINS_URL
#   HUBOT_JENKINS_AUTH - Optional; for authenticating the trigger request (user:password)
#
# Commands:
#   hubot ci issue <issue_number> - builds the pstat_ticket job with the corresponding issue_<issue_number> branch
#   hubot ci workers <N> - Launch N number of jenkins workers. N is optional and defaults to 1. Use "max" to use the default maximum number of workers.

# GCLOUD_PROJECT is passed in automatically from the env
moment = require('moment')
sprintf = require('sprintf-js').sprintf
URL = require('url-parse')

github = {}
gce = {}

CI_ENABLED = process.env.CI_ENABLED == 'true'

HUBOT_JENKINS_URL = process.env.HUBOT_JENKINS_URL
HUBOT_JENKINS_AUTH = process.env.HUBOT_JENKINS_AUTH
HUBOT_GITHUB_REPO = process.env.HUBOT_GITHUB_REPO

JENKINS_JNLP_CREDENTIALS = process.env.JENKINS_JNLP_CREDENTIALS
JENKINS_AGENT_LABEL = process.env.JENKINS_AGENT_LABEL
JENKINS_AGENT_AWS_ACCESS_KEY_ID = process.env.JENKINS_AGENT_AWS_ACCESS_KEY_ID
JENKINS_AGENT_AWS_SECRET_ACCESS_KEY = process.env.JENKINS_AGENT_AWS_SECRET_ACCESS_KEY

JENKINS_NOTIFICATION_ENDPOINT = process.env.JENKINS_NOTIFICATION_ENDPOINT or "/hubot/build-status"
JENKINS_ROOT_JOB_NOTIFICATION_ENDPOINT = process.env.JENKINS_ROOT_JOB_NOTIFICATION_ENDPOINT or "/hubot/root-build-status"
JENKINS_ROOT_JOB_NAME = process.env.JENKINS_ROOT_JOB_NAME or "pstat_ticket"

# These values can be obtained from the JSON key file you download when creating
# a service account.
# Required GCE configs
GCE_CREDENTIALS_CLIENT_EMAIL = process.env.GCE_CREDENTIALS_CLIENT_EMAIL
GCE_CREDENTIALS_PRIVATE_KEY = process.env.GCE_CREDENTIALS_PRIVATE_KEY
GCE_DISK_SOURCE_IMAGE = process.env.GCE_DISK_SOURCE_IMAGE
GCE_ZONE_NAMES = process.env.GCE_ZONE_NAMES.split(' ')
# Optional GCE configs
GCE_MACHINE_TYPE = process.env.GCE_MACHINE_TYPE or 'n1-highcpu-2'

GCE_COMPUTE_ENGINE_SERVICE_ACCOUNT_EMAIL = process.env.GCE_COMPUTE_ENGINE_SERVICE_ACCOUNT_EMAIL or ''
DISK_TYPE_TPL = 'zones/%s/diskTypes/pd-ssd'

JENKINS_BUILD_STATUS = {
  'FAILURE': 'FAILURE',
  'SUCCESS': 'SUCCESS',
  'ABORTED': 'ABORTED',
}
JENKINS_BUILD_PHASE = {
  'COMPLETED': 'COMPLETED',
  'STARTED': 'STARTED',
}
GITHUB_COMMIT_STATE = {
  'PENDING': 'pending',
  'FAILURE': 'failure',
  'SUCCESS': 'success',
}

jenkins_launch_workers = ({num_workers, force, image, label, jenkins_url}) ->
  console.log "jenkins_launch_workers(#{num_workers},#{force},#{image},#{label},#{jenkins_url})"

  instances = []
  zoneResultsCount = 0

  _aggregateVMsAcrossZones = (err, vms) ->
    if err
      console.log "Error retrieving current VM list: #{err}"
      return
    zoneResultsCount += 1
    instances = instances.concat(vms)
    remaining = GCE_ZONE_NAMES.length - zoneResultsCount
    if remaining <= 0
      _createWorkers()

  _createWorkers = () ->
    instanceCountByZone = _getInstanceCountByZone(instances)

    numRunningInstances = 0
    for zoneName of instanceCountByZone
      numRunningInstances += instanceCountByZone[zoneName]

    if force isnt true and numRunningInstances >= num_workers
      console.log "The requested number of workers #{num_workers} are already running"
      return

    workerNumbersByZone = _distributeWorkersAcrossZones(num_workers, instanceCountByZone)
    timestamp = moment().format 'MMDD-HHmmss-SS'  # e.g. 0901-134102-09
    for zoneName of workerNumbersByZone
      _createWorkersInZone(
        workerIndexes: workerNumbersByZone[zoneName]
        zoneName: zoneName
        timestamp: timestamp
        image: image
        label: label
        jenkins_url: jenkins_url
      )

  for zoneName in GCE_ZONE_NAMES
    zone = gce.zone(zoneName)
    # Determine which zones are busy, based on which currently have VMs,
    # so that we can spread our workers across zones.
    # This minimizes the likelihood of all of our workers being prempted at the same time.
    zone.getVMs(_aggregateVMsAcrossZones)

_getInstanceCountByZone = (instances) ->
  instanceCountByZone = {}
  for zoneName in GCE_ZONE_NAMES
    instanceCountByZone[zoneName] = 0

  for instance in instances
    # Only STAGING and RUNNING statuses indicate that there are available resources in a zone
    # see: https://cloud.google.com/compute/docs/instances/#checkmachinestatus
    status = instance.metadata.status
    if status in ['STAGING', 'RUNNING']
        instanceCountByZone[instance.zone.name] += 1
    else if status == 'TERMINATED'
      console.log "Deleting #{instance.name} with status #{status}"
      instance.delete()
    else
      console.log "Ignoring #{instance.name} with status #{status}"
  instanceCountByZone

_distributeWorkersAcrossZones = (num_workers, instanceCountByZone) ->
  maxWorkersPerZone = Math.ceil(num_workers / GCE_ZONE_NAMES.length)
  workerIndexes = [0...num_workers]

  # Distribute the indexes evenly across the zones.
  # The last zones will get 1 less if it doesn't work out evenly.
  # In the case of very low numbers (e.g. 5 nodes in 4 zones),
  # it's possible for zones to get no indexes.
  i = 0
  workerNumbersByZone = {}
  for zoneName of instanceCountByZone
    workerNumbersByZone[zoneName] = workerIndexes[i .. (i+maxWorkersPerZone)-1]
    i += maxWorkersPerZone
  workerNumbersByZone

_createWorkersInZone = ({workerIndexes, zoneName, timestamp, image, label, jenkins_url}) ->
  desiredMachineCount = workerIndexes.length
  if desiredMachineCount == 0
    return

  zone = gce.zone(zoneName)

  vmConfig = {
    machineType: GCE_MACHINE_TYPE
    disks: [
      {
        boot: true
        initializeParams: {
          sourceImage: "global/images/#{ image }"
          diskType: 'zones/us-central1-a/diskTypes/pd-ssd'
        }
        autoDelete: true
      }
    ]
    networkInterfaces: [
      {
        network: 'global/networks/default'
        accessConfigs: [
          {
            type: 'ONE_TO_ONE_NAT'
            name: 'External NAT'
          }
        ]
      }
    ]
    scheduling: {
      onHostMaintenance: 'TERMINATE'
      automaticRestart: false
      preemptible: true
    }
    metadata: {
      items: [
        {
          key: "JENKINS_URL"
          value: jenkins_url
        },
        {
          key: "JENKINS_AGENT_LABEL"
          value: label
        },
        {
          key: "JNLP_CREDENTIALS"
          value: JENKINS_JNLP_CREDENTIALS
        },
        {
          key: "AWS_ACCESS_KEY_ID"
          value: JENKINS_AGENT_AWS_ACCESS_KEY_ID
        },
        {
          key: "AWS_SECRET_ACCESS_KEY"
          value: JENKINS_AGENT_AWS_SECRET_ACCESS_KEY
        },
      ]
    }
  }
  console.log "Launching #{desiredMachineCount} machines in zone #{zone.name}"
  # The diskType config must be zone-specific
  vmConfig.disks[0].initializeParams.diskType = sprintf(DISK_TYPE_TPL, zone.name)
  if GCE_COMPUTE_ENGINE_SERVICE_ACCOUNT_EMAIL.length > 0
    vmConfig['serviceAccounts'] = [ {
      'email': GCE_COMPUTE_ENGINE_SERVICE_ACCOUNT_EMAIL
      'scopes': [ 'https://www.googleapis.com/auth/compute' ]
    } ]
  i = 0
  while i < desiredMachineCount
    vmName = sprintf('worker-%s-%02d-%s', timestamp, workerIndexes[i], zoneName)
    console.log "Creating VM: #{vmName}"
    zone.createVM vmName, vmConfig, (err, vm, operation, response) ->
      if err
        console.log "Error creating #{vm.name}: #{err}"
      else
        console.log "VM creation call succeeded for: #{vm.name} with #{operation.name}"
    i++

update_github_commit_status = ({context, commit_sha, state, target_url, description}) ->
  repo = github.qualified_repo(HUBOT_GITHUB_REPO)
  data = (
    context: context
    state: state
    target_url: target_url
    description: description
  )
  callback_func = ->
  github.post("repos/#{repo}/statuses/#{commit_sha}", data, callback_func)

_parse_ci_option_string = (raw_options) ->
  raw_options = raw_options or ''

  options = new ->
    for param in raw_options.split(',')
      params = param.split('=')
      @[params[0]] = params[1]
    this

  source_image = GCE_DISK_SOURCE_IMAGE
  label = JENKINS_AGENT_LABEL
  jenkins_url = HUBOT_JENKINS_URL

  if options?
    if options.image?
      source_image = options.image
    if options.label?
      label = options.label
    if options.url?
      jenkins_url = options.url

  return (
    image: source_image
    label: label
    jenkins_url: jenkins_url
  )

handle_command_ci_workers = (msg) ->
  if CI_ENABLED is false
    msg.send "CI system is currently disabled"
    return

  num_workers = msg.match[1] or 1
  options = _parse_ci_option_string(msg.match[2])

  jenkins_launch_workers(
    num_workers: num_workers
    force: true
    image: options.image
    label: options.label
    jenkins_url: options.jenkins_url
  )
  msg.send "Launching #{num_workers} Jenkins workers"

handle_command_ci_issue = (robot, msg) ->
  if CI_ENABLED is false
    msg.send "CI system is currently disabled"
    return

  baseUrl = HUBOT_JENKINS_URL
  issue = msg.match[1]
  branch = "issue_#{issue}"
  channelId = msg.message.rawMessage.channel

  url = "#{baseUrl}/job/#{JENKINS_ROOT_JOB_NAME}/buildWithParameters?GIT_BRANCH=#{branch}"
  req = msg.http(url)
  if HUBOT_JENKINS_AUTH
    auth = new Buffer(HUBOT_JENKINS_AUTH).toString('base64')
    req.headers Authorization: "Basic #{auth}"

  req.header('Content-Length', 0)
  req.post() (err, res, body) ->
      if err
        message = "Jenkins reported an error: #{err}"
      else if res.statusCode == 201
        message = "#{JENKINS_ROOT_JOB_NAME} #{branch}: Queued"
        robot.brain.set(branch, channelId)
      else
        message = "Jenkins responded with status code #{res.statusCode}"
      robot.messageRoom(channelId, message)


module.exports = (robot) ->
  github = require("githubot")(robot)
  gcloud = require('gcloud')
  gce = gcloud.compute(
    credentials:
      client_email: GCE_CREDENTIALS_CLIENT_EMAIL
      private_key: GCE_CREDENTIALS_PRIVATE_KEY
  )

  github.handleErrors (response) ->
    console.log "Oh noes! A github request returned #{response.statusCode}"
    console.log "and error message: #{response.error}"
    console.log "and body: #{response.body}"

  robot.respond /message test/i, (msg) ->
    channelId = msg.message.rawMessage.channel
    robot.messageRoom channelId, "pong - channel ID is #{channelId}"

  robot.respond /ci issue ([\d_]+)/i, (msg) ->
    handle_command_ci_issue(robot, msg)

  robot.respond /ci workers ?(\d+)? ?([\S]*)/i, (msg) ->
    handle_command_ci_workers(msg)

  robot.router.post JENKINS_NOTIFICATION_ENDPOINT, (req, res) ->
    build = req.body.build
    job_name = req.body.name
    build_id = build.parameters.ROOT_JOB_UUID
    commit_sha = build.parameters.GIT_COMMIT

    github_state = null
    description = ""
    if build.phase is JENKINS_BUILD_PHASE.STARTED
      github_state = GITHUB_COMMIT_STATE.PENDING
    else if build.phase is JENKINS_BUILD_PHASE.COMPLETED
      tests = build.test_summary
      if tests
        description = "Total:#{tests.total} Skipped:#{tests.skipped} Passed:#{tests.passed} Failed:#{tests.failed}"
      if build.status is JENKINS_BUILD_STATUS.SUCCESS
        github_state = GITHUB_COMMIT_STATE.SUCCESS
      else
        github_state = GITHUB_COMMIT_STATE.FAILURE

    if github_state
      console.log "#{job_name} #{build_id} #{build.phase} #{build.status} #{commit_sha}"

      update_github_commit_status(
        context: job_name
        commit_sha: commit_sha
        state: github_state
        target_url: build.full_url
        description: description
      )

    res.end "ok"

  robot.router.post JENKINS_ROOT_JOB_NOTIFICATION_ENDPOINT, (req, res) ->
    num_workers = 170
    build = req.body.build

    if build.notes == '' or build.notes == '${ROOT_JOB_UUID}'
      build_id = build.number
    else
      build_id = build.notes  # notes should have UUID

    job_name = req.body.name
    full_url = build.full_url
    jenkins_host = new URL(full_url).origin
    worker_image = build.parameters.WORKER_IMAGE or GCE_DISK_SOURCE_IMAGE
    worker_label = build.parameters.WORKER_LABEL or JENKINS_AGENT_LABEL
    commit_sha = build.scm.commit
    git_branch = build.scm.branch
    slack_room = robot.brain.get(git_branch)

    console.log "#{job_name} #{git_branch} #{commit_sha} #{build_id} #{jenkins_host} #{build.phase} #{build.status}"

    slack_message = null

    if build.phase is JENKINS_BUILD_PHASE.STARTED
      slack_message = "Started"

    else if build.phase is JENKINS_BUILD_PHASE.COMPLETED
      slack_message = "Failure"
      github_state = GITHUB_COMMIT_STATE.FAILURE

      if build.status is JENKINS_BUILD_STATUS.SUCCESS
        slack_message = "Completed Successfully :confetti_ball:"
        github_state = GITHUB_COMMIT_STATE.SUCCESS

        jenkins_launch_workers(
          num_workers: num_workers
          force: false
          image: worker_image
          label: worker_label
          jenkins_url: jenkins_host
        )

      update_github_commit_status(
        context: job_name
        commit_sha: commit_sha
        state: github_state
        target_url: build.full_url
        description: ""
      )

    if slack_room and slack_message
      robot.messageRoom(slack_room, "<#{full_url}|#{job_name}/#{git_branch}>: #{slack_message}")



    res.end "ok"
